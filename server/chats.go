package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

type File struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Mime       string `json:"mime"`
	Size       int64  `json:"size"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	DurationMs int64  `json:"duration_ms"`
}

type Message struct {
	ID        int64     `json:"id"`
	ChatID    int64     `json:"chat_id"`
	SenderID  int64     `json:"sender_id"`
	ClientID  string    `json:"client_id"`
	Kind      string    `json:"kind"`
	Text      string    `json:"text"`
	File      *File     `json:"file"`
	ReplyToID *int64    `json:"reply_to_id"`
	CreatedAt int64     `json:"created_at"`
	Deleted   bool      `json:"deleted"`
	Call      *CallInfo `json:"call,omitempty"`
}

type Chat struct {
	ID           int64    `json:"id"`
	Kind         string   `json:"kind"`
	Title        string   `json:"title"`
	AvatarFileID *string  `json:"avatar_file_id"`
	MemberIDs    []int64  `json:"member_ids"`
	LastMessage  *Message `json:"last_message"`
	Unread       int      `json:"unread"`
	LastReadID   int64    `json:"last_read_id"`
	OthersReadID int64    `json:"others_read_id"`

	activity int64
}

const (
	maxTextLen   = 10000
	selfChatName = "Избранное"
)

const messageSelect = `
SELECT m.id, m.chat_id, m.sender_id, m.client_id, m.kind, m.text, m.reply_to_id, m.created_at, m.deleted,
       f.id, f.name, f.mime, f.size, f.width, f.height, f.duration_ms,
       cl.id, cl.video, cl.state, cl.answered_at, cl.ended_at
FROM messages m LEFT JOIN files f ON f.id = m.file_id LEFT JOIN calls cl ON cl.id = m.call_id`

func scanMessage(sc interface{ Scan(...any) error }) (*Message, error) {
	var m Message
	var reply sql.NullInt64
	var fid, fname, fmime sql.NullString
	var fsize, fw, fh, fdur sql.NullInt64
	var cid, cvideo, cans, cend sql.NullInt64
	var cstate sql.NullString
	if err := sc.Scan(&m.ID, &m.ChatID, &m.SenderID, &m.ClientID, &m.Kind, &m.Text, &reply, &m.CreatedAt, &m.Deleted,
		&fid, &fname, &fmime, &fsize, &fw, &fh, &fdur,
		&cid, &cvideo, &cstate, &cans, &cend); err != nil {
		return nil, err
	}
	if cid.Valid {
		ci := &CallInfo{ID: cid.Int64, Video: cvideo.Int64 != 0, State: cstate.String}
		if cans.Valid && cend.Valid && cend.Int64 > cans.Int64 {
			ci.DurationMs = cend.Int64 - cans.Int64
		}
		m.Call = ci
	}
	if reply.Valid {
		m.ReplyToID = &reply.Int64
	}
	if fid.Valid {
		m.File = &File{ID: fid.String, Name: fname.String, Mime: fmime.String, Size: fsize.Int64,
			Width: int(fw.Int64), Height: int(fh.Int64), DurationMs: fdur.Int64}
	}
	return &m, nil
}

func (app *App) getMessage(ctx context.Context, id int64) (*Message, error) {
	m, err := scanMessage(app.db.QueryRowContext(ctx, messageSelect+` WHERE m.id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	return m, err
}

func (app *App) isMember(ctx context.Context, chatID, uid int64) error {
	var one int
	err := app.db.QueryRowContext(ctx, `SELECT 1 FROM chat_members WHERE chat_id = ? AND user_id = ?`, chatID, uid).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	return err
}

func (app *App) chatMemberIDs(ctx context.Context, chatID int64) ([]int64, error) {
	rows, err := app.db.QueryContext(ctx, `SELECT user_id FROM chat_members WHERE chat_id = ? ORDER BY user_id`, chatID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

const chatSelect = `
SELECT c.id, c.kind, c.title, c.avatar_file_id, c.created_at, cm.last_read_id,
  (SELECT MAX(id) FROM messages m WHERE m.chat_id = c.id AND m.deleted = 0),
  (SELECT COUNT(*) FROM messages m WHERE m.chat_id = c.id AND m.id > cm.last_read_id AND m.sender_id <> cm.user_id AND m.deleted = 0),
  (SELECT COALESCE(MAX(o.last_read_id), 0) FROM chat_members o WHERE o.chat_id = c.id AND o.user_id <> cm.user_id)
FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = ?`

// chatsForUser returns the user's chats (optionally just one) as that user sees them.
func (app *App) chatsForUser(ctx context.Context, uid int64, onlyChat int64) ([]*Chat, error) {
	q := chatSelect
	args := []any{uid}
	if onlyChat > 0 {
		q += ` WHERE c.id = ?`
		args = append(args, onlyChat)
	}
	rows, err := app.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	type row struct {
		chat   *Chat
		lastID sql.NullInt64
	}
	var list []row
	for rows.Next() {
		c := &Chat{}
		var avatar sql.NullString
		var r row
		if err := rows.Scan(&c.ID, &c.Kind, &c.Title, &avatar, &c.activity, &c.LastReadID, &r.lastID, &c.Unread, &c.OthersReadID); err != nil {
			rows.Close()
			return nil, err
		}
		if avatar.Valid {
			c.AvatarFileID = &avatar.String
		}
		r.chat = c
		list = append(list, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	chats := make([]*Chat, 0, len(list))
	for _, r := range list {
		c := r.chat
		if c.MemberIDs, err = app.chatMemberIDs(ctx, c.ID); err != nil {
			return nil, err
		}
		if r.lastID.Valid {
			if c.LastMessage, err = app.getMessage(ctx, r.lastID.Int64); err != nil {
				return nil, err
			}
			c.activity = c.LastMessage.CreatedAt
		}
		if c.Kind == "direct" {
			c.Title = selfChatName
			for _, id := range c.MemberIDs {
				if id != uid {
					var name string
					var av sql.NullString
					if err := app.db.QueryRowContext(ctx, `SELECT display_name, avatar_file_id FROM users WHERE id = ?`, id).Scan(&name, &av); err == nil {
						c.Title = name
						if av.Valid {
							c.AvatarFileID = &av.String
						}
					}
				}
			}
		}
		chats = append(chats, c)
	}
	sort.SliceStable(chats, func(i, j int) bool {
		if chats[i].activity != chats[j].activity {
			return chats[i].activity > chats[j].activity
		}
		return chats[i].ID > chats[j].ID
	})
	return chats, nil
}

func (app *App) chatForUser(ctx context.Context, uid, chatID int64) (*Chat, error) {
	chats, err := app.chatsForUser(ctx, uid, chatID)
	if err != nil {
		return nil, err
	}
	if len(chats) == 0 {
		return nil, errNotFound
	}
	return chats[0], nil
}

func (app *App) broadcastChat(ctx context.Context, chatID int64, typ string, data any, except int64) {
	ids, err := app.chatMemberIDs(ctx, chatID)
	if err != nil {
		return
	}
	for _, id := range ids {
		if id != except {
			app.hub.send(id, typ, data)
		}
	}
}

// ---- handlers ----

func (app *App) handleListChats(w http.ResponseWriter, r *http.Request, u *User) error {
	chats, err := app.chatsForUser(r.Context(), u.ID, 0)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, chats)
	return nil
}

func (app *App) handleCreateChat(w http.ResponseWriter, r *http.Request, u *User) error {
	var req struct {
		Kind      string  `json:"kind"`
		UserID    int64   `json:"user_id"`
		Title     string  `json:"title"`
		MemberIDs []int64 `json:"member_ids"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	userExists := func(id int64) bool {
		var one int
		return app.db.QueryRowContext(ctx, `SELECT 1 FROM users WHERE id = ?`, id).Scan(&one) == nil
	}

	var members []int64
	var title string
	var directKey any
	switch req.Kind {
	case "direct":
		if !userExists(req.UserID) {
			return errStatus(http.StatusBadRequest, "user not found")
		}
		a, b := u.ID, req.UserID
		if a > b {
			a, b = b, a
		}
		key := fmt.Sprintf("%d:%d", a, b)
		var existing int64
		err := app.db.QueryRowContext(ctx, `SELECT id FROM chats WHERE direct_key = ?`, key).Scan(&existing)
		if err == nil {
			c, err := app.chatForUser(ctx, u.ID, existing)
			if err != nil {
				return err
			}
			writeJSON(w, http.StatusOK, c)
			return nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		directKey = key
		members = []int64{u.ID}
		if req.UserID != u.ID {
			members = append(members, req.UserID)
		}
	case "group":
		title = strings.TrimSpace(req.Title)
		if title == "" || utf8.RuneCountInString(title) > 128 {
			return errStatus(http.StatusBadRequest, "title required (max 128 chars)")
		}
		seen := map[int64]bool{u.ID: true}
		members = []int64{u.ID}
		for _, id := range req.MemberIDs {
			if seen[id] {
				continue
			}
			if !userExists(id) {
				return errStatus(http.StatusBadRequest, "user not found: "+strconv.FormatInt(id, 10))
			}
			seen[id] = true
			members = append(members, id)
		}
	default:
		return errStatus(http.StatusBadRequest, `kind must be "direct" or "group"`)
	}

	tx, err := app.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	now := nowMs()
	res, err := tx.Exec(`INSERT INTO chats (kind, title, direct_key, created_by, created_at) VALUES (?, ?, ?, ?, ?)`,
		req.Kind, title, directKey, u.ID, now)
	if err != nil {
		return err
	}
	chatID, _ := res.LastInsertId()
	for _, id := range members {
		if _, err := tx.Exec(`INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES (?, ?, ?)`, chatID, id, now); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	app.broadcastChat(ctx, chatID, "chat.new", map[string]int64{"chat_id": chatID}, 0)
	c, err := app.chatForUser(ctx, u.ID, chatID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, c)
	return nil
}

func (app *App) handleListMessages(w http.ResponseWriter, r *http.Request, u *User) error {
	chatID, err := pathID(r, "id")
	if err != nil {
		return err
	}
	ctx := r.Context()
	if err := app.isMember(ctx, chatID, u.ID); err != nil {
		return err
	}
	limit := 50
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			limit = min(n, 200)
		}
	}
	q := messageSelect + ` WHERE m.chat_id = ?`
	args := []any{chatID}
	if s := r.URL.Query().Get("before"); s != "" {
		before, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return errStatus(http.StatusBadRequest, "invalid before")
		}
		q += ` AND m.id < ?`
		args = append(args, before)
	}
	q += ` ORDER BY m.id DESC LIMIT ?`
	args = append(args, limit)
	rows, err := app.db.QueryContext(ctx, q, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	msgs := []*Message{}
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}
	writeJSON(w, http.StatusOK, msgs)
	return nil
}

func kindForMime(mime string) string {
	switch {
	case strings.HasPrefix(mime, "image/") && mime != "image/svg+xml":
		return "image"
	case strings.HasPrefix(mime, "video/"):
		return "video"
	}
	return "file"
}

func (app *App) handleSendMessage(w http.ResponseWriter, r *http.Request, u *User) error {
	chatID, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		ClientID  string `json:"client_id"`
		Kind      string `json:"kind"`
		Text      string `json:"text"`
		FileID    string `json:"file_id"`
		ReplyToID *int64 `json:"reply_to_id"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	if err := app.isMember(ctx, chatID, u.ID); err != nil {
		return err
	}
	if req.ClientID == "" || len(req.ClientID) > 64 {
		return errStatus(http.StatusBadRequest, "client_id required (max 64 chars)")
	}
	// Idempotent retry: same sender + client_id returns the original message.
	var existing int64
	err = app.db.QueryRowContext(ctx, `SELECT id FROM messages WHERE sender_id = ? AND client_id = ?`, u.ID, req.ClientID).Scan(&existing)
	if err == nil {
		m, err := app.getMessage(ctx, existing)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, m)
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	text := strings.TrimRight(req.Text, " \t\r\n")
	if utf8.RuneCountInString(text) > maxTextLen {
		return errStatus(http.StatusBadRequest, "text too long")
	}
	kind := "text"
	var fileID any
	if req.FileID != "" {
		var mime string
		var uploader int64
		err := app.db.QueryRowContext(ctx, `SELECT mime, uploader_id FROM files WHERE id = ?`, req.FileID).Scan(&mime, &uploader)
		if errors.Is(err, sql.ErrNoRows) || (err == nil && uploader != u.ID && !app.fileAccessible(ctx, req.FileID, u.ID)) {
			return errStatus(http.StatusBadRequest, "file not found")
		}
		if err != nil {
			return err
		}
		switch req.Kind {
		case "image", "video", "file", "voice":
			kind = req.Kind
		case "", "text":
			kind = kindForMime(mime)
		default:
			return errStatus(http.StatusBadRequest, "invalid kind")
		}
		fileID = req.FileID
	} else if strings.TrimSpace(text) == "" {
		return errStatus(http.StatusBadRequest, "empty message")
	}
	var replyTo any
	if req.ReplyToID != nil {
		var c int64
		err := app.db.QueryRowContext(ctx, `SELECT chat_id FROM messages WHERE id = ?`, *req.ReplyToID).Scan(&c)
		if err != nil || c != chatID {
			return errStatus(http.StatusBadRequest, "reply_to_id not in this chat")
		}
		replyTo = *req.ReplyToID
	}

	res, err := app.db.ExecContext(ctx, `INSERT INTO messages (chat_id, sender_id, client_id, kind, text, file_id, reply_to_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, chatID, u.ID, req.ClientID, kind, text, fileID, replyTo, nowMs())
	if err != nil {
		return err
	}
	id, _ := res.LastInsertId()
	// Sending implies the sender has read everything up to here.
	_, _ = app.db.ExecContext(ctx, `UPDATE chat_members SET last_read_id = ? WHERE chat_id = ? AND user_id = ? AND last_read_id < ?`, id, chatID, u.ID, id)
	m, err := app.getMessage(ctx, id)
	if err != nil {
		return err
	}
	app.broadcastChat(ctx, chatID, "message.new", m, 0)
	app.notifyNewMessage(m, u)
	writeJSON(w, http.StatusOK, m)
	return nil
}

func (app *App) handleRead(w http.ResponseWriter, r *http.Request, u *User) error {
	chatID, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		MessageID int64 `json:"message_id"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	if err := app.isMember(ctx, chatID, u.ID); err != nil {
		return err
	}
	var maxID int64
	_ = app.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM messages WHERE chat_id = ?`, chatID).Scan(&maxID)
	target := min(req.MessageID, maxID)
	res, err := app.db.ExecContext(ctx, `UPDATE chat_members SET last_read_id = ? WHERE chat_id = ? AND user_id = ? AND last_read_id < ?`,
		target, chatID, u.ID, target)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		app.broadcastChat(ctx, chatID, "chat.read", map[string]int64{"chat_id": chatID, "user_id": u.ID, "message_id": target}, 0)
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	return nil
}

func (app *App) handleDeleteMessage(w http.ResponseWriter, r *http.Request, u *User) error {
	id, err := pathID(r, "id")
	if err != nil {
		return err
	}
	ctx := r.Context()
	var chatID, sender int64
	err = app.db.QueryRowContext(ctx, `SELECT chat_id, sender_id FROM messages WHERE id = ? AND deleted = 0`, id).Scan(&chatID, &sender)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	if sender != u.ID {
		return errForbidden
	}
	if _, err := app.db.ExecContext(ctx, `UPDATE messages SET deleted = 1, text = '', file_id = NULL WHERE id = ?`, id); err != nil {
		return err
	}
	app.broadcastChat(ctx, chatID, "message.deleted", map[string]int64{"chat_id": chatID, "id": id}, 0)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	return nil
}
