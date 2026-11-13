package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/livekit/protocol/auth"
	"github.com/livekit/protocol/webhook"
)

// Call states.
const (
	callRinging  = "ringing"
	callActive   = "active"
	callEnded    = "ended"
	callMissed   = "missed"
	callDeclined = "declined"
)

const (
	defaultRingTimeout = 45 * time.Second
	callTokenTTL       = 6 * time.Hour
	callRoomPrefix     = "call-"
)

var errCallsDisabled = errStatus(http.StatusServiceUnavailable, "Звонки не настроены")

type Call struct {
	ID             int64   `json:"id"`
	ChatID         int64   `json:"chat_id"`
	InitiatorID    int64   `json:"initiator_id"`
	Video          bool    `json:"video"`
	State          string  `json:"state"`
	ParticipantIDs []int64 `json:"participant_ids"`
	CreatedAt      int64   `json:"created_at"`
	AnsweredAt     *int64  `json:"answered_at"`
	EndedAt        *int64  `json:"ended_at"`
}

func (c *Call) live() bool { return c.State == callRinging || c.State == callActive }

// CallInfo is the summary embedded in a chat message of kind "call".
type CallInfo struct {
	ID         int64  `json:"id"`
	Video      bool   `json:"video"`
	State      string `json:"state"`
	DurationMs int64  `json:"duration_ms"`
}

type CallJoin struct {
	Call       *Call  `json:"call"`
	LiveKitURL string `json:"livekit_url"`
	Token      string `json:"token"`
}

// callRuntime serializes call state transitions and owns ring timers.
type callRuntime struct {
	mu          sync.Mutex
	timers      map[int64]*time.Timer
	ringTimeout time.Duration // 0 = defaultRingTimeout (tests shorten it)
}

func (app *App) callsEnabled() bool {
	return app.cfg.LiveKitURL != "" && app.cfg.LiveKitKey != "" && app.cfg.LiveKitSecret != ""
}

func roomName(callID int64) string { return callRoomPrefix + strconv.FormatInt(callID, 10) }

func (app *App) liveKitToken(callID int64, u *User) (string, error) {
	at := auth.NewAccessToken(app.cfg.LiveKitKey, app.cfg.LiveKitSecret).
		SetIdentity(strconv.FormatInt(u.ID, 10)).
		SetName(u.DisplayName).
		SetValidFor(callTokenTTL).
		SetVideoGrant(&auth.VideoGrant{RoomJoin: true, Room: roomName(callID)})
	return at.ToJWT()
}

// ---- storage ----

const callCols = `id, chat_id, initiator_id, video, state, created_at, answered_at, ended_at`

func (app *App) scanCall(ctx context.Context, sc interface{ Scan(...any) error }) (*Call, error) {
	var c Call
	var ans, end sql.NullInt64
	if err := sc.Scan(&c.ID, &c.ChatID, &c.InitiatorID, &c.Video, &c.State, &c.CreatedAt, &ans, &end); err != nil {
		return nil, err
	}
	if ans.Valid {
		c.AnsweredAt = &ans.Int64
	}
	if end.Valid {
		c.EndedAt = &end.Int64
	}
	return &c, nil
}

// fillParticipants: current participants for live calls, everyone who joined for finished ones.
func (app *App) fillParticipants(ctx context.Context, c *Call) error {
	q := `SELECT user_id FROM call_participants WHERE call_id = ?`
	if c.live() {
		q += ` AND left_at IS NULL`
	}
	rows, err := app.db.QueryContext(ctx, q+` ORDER BY joined_at, user_id`, c.ID)
	if err != nil {
		return err
	}
	defer rows.Close()
	c.ParticipantIDs = []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return err
		}
		c.ParticipantIDs = append(c.ParticipantIDs, id)
	}
	return rows.Err()
}

func (app *App) getCall(ctx context.Context, id int64) (*Call, error) {
	c, err := app.scanCall(ctx, app.db.QueryRowContext(ctx, `SELECT `+callCols+` FROM calls WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, err
	}
	return c, app.fillParticipants(ctx, c)
}

// callForMember loads a call the user may see (member of its chat), else 404.
func (app *App) callForMember(ctx context.Context, id, uid int64) (*Call, error) {
	c, err := app.getCall(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := app.isMember(ctx, c.ChatID, uid); err != nil {
		return nil, err
	}
	return c, nil
}

func (app *App) chatKind(ctx context.Context, chatID int64) (string, error) {
	var kind string
	err := app.db.QueryRowContext(ctx, `SELECT kind FROM chats WHERE id = ?`, chatID).Scan(&kind)
	if errors.Is(err, sql.ErrNoRows) {
		return "", errNotFound
	}
	return kind, err
}

func (app *App) addParticipant(ctx context.Context, callID, uid int64) error {
	_, err := app.db.ExecContext(ctx, `INSERT INTO call_participants (call_id, user_id, joined_at) VALUES (?, ?, ?)
		ON CONFLICT (call_id, user_id) DO UPDATE SET left_at = NULL`, callID, uid, nowMs())
	return err
}

func (app *App) activeParticipants(ctx context.Context, callID int64) (int, error) {
	var n int
	err := app.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM call_participants WHERE call_id = ? AND left_at IS NULL`, callID).Scan(&n)
	return n, err
}

// ---- transitions (callers hold app.calls.mu) ----

func (app *App) joinLocked(ctx context.Context, c *Call, u *User) (*CallJoin, error) {
	if !c.live() {
		return nil, errStatus(http.StatusConflict, "Звонок уже завершён")
	}
	if err := app.addParticipant(ctx, c.ID, u.ID); err != nil {
		return nil, err
	}
	if c.State == callRinging && u.ID != c.InitiatorID {
		now := nowMs()
		if _, err := app.db.ExecContext(ctx, `UPDATE calls SET state = ?, answered_at = ? WHERE id = ?`, callActive, now, c.ID); err != nil {
			return nil, err
		}
		app.stopRingTimer(c.ID)
	}
	fresh, err := app.getCall(ctx, c.ID)
	if err != nil {
		return nil, err
	}
	app.broadcastChat(ctx, fresh.ChatID, "call.updated", fresh, 0)
	token, err := app.liveKitToken(fresh.ID, u)
	if err != nil {
		return nil, err
	}
	return &CallJoin{Call: fresh, LiveKitURL: app.cfg.LiveKitURL, Token: token}, nil
}

// endLocked finishes a live call, records it in the chat and notifies members.
func (app *App) endLocked(ctx context.Context, c *Call, state string) error {
	if !c.live() {
		return nil
	}
	app.stopRingTimer(c.ID)
	now := nowMs()
	res, err := app.db.ExecContext(ctx, `UPDATE calls SET state = ?, ended_at = ? WHERE id = ? AND state IN (?, ?)`,
		state, now, c.ID, callRinging, callActive)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil
	}
	_, _ = app.db.ExecContext(ctx, `UPDATE call_participants SET left_at = ? WHERE call_id = ? AND left_at IS NULL`, now, c.ID)

	text := "Аудиозвонок"
	switch {
	case state == callMissed:
		text = "Пропущенный звонок"
	case state == callDeclined:
		text = "Отклонённый звонок"
	case c.Video:
		text = "Видеозвонок"
	}
	msgID, err := app.insertCallMessage(ctx, c, text, now)
	if err != nil {
		return err
	}
	fresh, err := app.getCall(ctx, c.ID)
	if err != nil {
		return err
	}
	app.broadcastChat(ctx, fresh.ChatID, "call.ended", fresh, 0)
	if m, err := app.getMessage(ctx, msgID); err == nil {
		app.broadcastChat(ctx, fresh.ChatID, "message.new", m, 0)
	}
	return nil
}

func (app *App) insertCallMessage(ctx context.Context, c *Call, text string, at int64) (int64, error) {
	res, err := app.db.ExecContext(ctx, `INSERT INTO messages (chat_id, sender_id, client_id, kind, text, call_id, created_at)
		VALUES (?, ?, ?, 'call', ?, ?, ?)
		ON CONFLICT (sender_id, client_id) DO NOTHING`,
		c.ChatID, c.InitiatorID, fmt.Sprintf("call-%d", c.ID), text, c.ID, at)
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	if n, _ := res.RowsAffected(); n == 0 {
		err = app.db.QueryRowContext(ctx, `SELECT id FROM messages WHERE call_id = ?`, c.ID).Scan(&id)
	}
	// The initiator "wrote" it, so it is read for them.
	_, _ = app.db.ExecContext(ctx, `UPDATE chat_members SET last_read_id = ? WHERE chat_id = ? AND user_id = ? AND last_read_id < ?`,
		id, c.ChatID, c.InitiatorID, id)
	return id, err
}

// leaveLocked removes a user; ends the call when it should no longer exist.
func (app *App) leaveLocked(ctx context.Context, c *Call, uid int64) error {
	if !c.live() {
		return nil
	}
	if _, err := app.db.ExecContext(ctx, `UPDATE call_participants SET left_at = ? WHERE call_id = ? AND user_id = ? AND left_at IS NULL`,
		nowMs(), c.ID, uid); err != nil {
		return err
	}
	endState := callEnded
	if c.State == callRinging {
		endState = callMissed // nobody answered before the caller gave up
	}
	kind, err := app.chatKind(ctx, c.ChatID)
	if err != nil {
		return err
	}
	if kind == "direct" {
		return app.endLocked(ctx, c, endState)
	}
	n, err := app.activeParticipants(ctx, c.ID)
	if err != nil {
		return err
	}
	if n == 0 {
		return app.endLocked(ctx, c, endState)
	}
	fresh, err := app.getCall(ctx, c.ID)
	if err != nil {
		return err
	}
	app.broadcastChat(ctx, fresh.ChatID, "call.updated", fresh, 0)
	return nil
}

// ---- ring timers ----

func (app *App) ringTimeout() time.Duration {
	if app.calls.ringTimeout > 0 {
		return app.calls.ringTimeout
	}
	return defaultRingTimeout
}

func (app *App) startRingTimer(callID int64) {
	if app.calls.timers == nil {
		app.calls.timers = map[int64]*time.Timer{}
	}
	app.calls.timers[callID] = time.AfterFunc(app.ringTimeout(), func() { app.ringExpired(callID) })
}

func (app *App) stopRingTimer(callID int64) {
	if t, ok := app.calls.timers[callID]; ok {
		t.Stop()
		delete(app.calls.timers, callID)
	}
}

func (app *App) ringExpired(callID int64) {
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	delete(app.calls.timers, callID)
	ctx := context.Background()
	c, err := app.getCall(ctx, callID)
	if err != nil || c.State != callRinging {
		return
	}
	if err := app.endLocked(ctx, c, callMissed); err != nil {
		log.Printf("call %d: ring timeout: %v", callID, err)
	}
}

// recoverCalls finishes calls left live by a previous process (timers are gone).
func (app *App) recoverCalls(ctx context.Context) error {
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	rows, err := app.db.QueryContext(ctx, `SELECT `+callCols+` FROM calls WHERE state IN (?, ?)`, callRinging, callActive)
	if err != nil {
		return err
	}
	var stale []*Call
	for rows.Next() {
		c, err := app.scanCall(ctx, rows)
		if err != nil {
			rows.Close()
			return err
		}
		stale = append(stale, c)
	}
	rows.Close()
	for _, c := range stale {
		state := callEnded
		if c.State == callRinging {
			state = callMissed
		}
		if err := app.endLocked(ctx, c, state); err != nil {
			return err
		}
	}
	return nil
}

// ---- handlers ----

func (app *App) handleStartCall(w http.ResponseWriter, r *http.Request, u *User) error {
	if !app.callsEnabled() {
		return errCallsDisabled
	}
	chatID, err := pathID(r, "id")
	if err != nil {
		return err
	}
	var req struct {
		Video bool `json:"video"`
	}
	if r.ContentLength != 0 {
		if err := readJSON(r, &req); err != nil {
			return err
		}
	}
	ctx := r.Context()
	if err := app.isMember(ctx, chatID, u.ID); err != nil {
		return err
	}
	members, err := app.chatMemberIDs(ctx, chatID)
	if err != nil {
		return err
	}
	if len(members) < 2 {
		return errStatus(http.StatusBadRequest, "Некому звонить")
	}

	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()

	// One live call per chat: starting again joins it.
	existing, err := app.scanCall(ctx, app.db.QueryRowContext(ctx,
		`SELECT `+callCols+` FROM calls WHERE chat_id = ? AND state IN (?, ?) ORDER BY id DESC LIMIT 1`,
		chatID, callRinging, callActive))
	if err == nil {
		if err := app.fillParticipants(ctx, existing); err != nil {
			return err
		}
		join, err := app.joinLocked(ctx, existing, u)
		if err != nil {
			return err
		}
		writeJSON(w, http.StatusOK, join)
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	res, err := app.db.ExecContext(ctx, `INSERT INTO calls (chat_id, initiator_id, video, state, created_at) VALUES (?, ?, ?, ?, ?)`,
		chatID, u.ID, req.Video, callRinging, nowMs())
	if err != nil {
		return err
	}
	callID, _ := res.LastInsertId()
	if err := app.addParticipant(ctx, callID, u.ID); err != nil {
		return err
	}
	c, err := app.getCall(ctx, callID)
	if err != nil {
		return err
	}
	token, err := app.liveKitToken(callID, u)
	if err != nil {
		return err
	}
	app.startRingTimer(callID)
	app.broadcastChat(ctx, chatID, "call.ring", c, u.ID)
	writeJSON(w, http.StatusOK, &CallJoin{Call: c, LiveKitURL: app.cfg.LiveKitURL, Token: token})
	return nil
}

func (app *App) callFromPath(r *http.Request, u *User) (*Call, error) {
	if !app.callsEnabled() {
		return nil, errCallsDisabled
	}
	id, err := pathID(r, "id")
	if err != nil {
		return nil, err
	}
	return app.callForMember(r.Context(), id, u.ID)
}

func (app *App) handleJoinCall(w http.ResponseWriter, r *http.Request, u *User) error {
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	c, err := app.callFromPath(r, u)
	if err != nil {
		return err
	}
	join, err := app.joinLocked(r.Context(), c, u)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, join)
	return nil
}

func (app *App) handleDeclineCall(w http.ResponseWriter, r *http.Request, u *User) error {
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	c, err := app.callFromPath(r, u)
	if err != nil {
		return err
	}
	ctx := r.Context()
	if c.State == callRinging && u.ID != c.InitiatorID {
		kind, err := app.chatKind(ctx, c.ChatID)
		if err != nil {
			return err
		}
		if kind == "direct" {
			if err := app.endLocked(ctx, c, callDeclined); err != nil {
				return err
			}
		}
		// In a group, one person declining doesn't stop the others' ringing.
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (app *App) handleLeaveCall(w http.ResponseWriter, r *http.Request, u *User) error {
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	c, err := app.callFromPath(r, u)
	if err != nil {
		return err
	}
	if err := app.leaveLocked(r.Context(), c, u.ID); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (app *App) handleListCalls(w http.ResponseWriter, r *http.Request, u *User) error {
	limit := 50
	if s := r.URL.Query().Get("limit"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			limit = min(n, 200)
		}
	}
	ctx := r.Context()
	rows, err := app.db.QueryContext(ctx, `SELECT `+callCols+` FROM calls
		WHERE chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)
		ORDER BY id DESC LIMIT ?`, u.ID, limit)
	if err != nil {
		return err
	}
	calls := []*Call{}
	for rows.Next() {
		c, err := app.scanCall(ctx, rows)
		if err != nil {
			rows.Close()
			return err
		}
		calls = append(calls, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, c := range calls {
		if err := app.fillParticipants(ctx, c); err != nil {
			return err
		}
	}
	writeJSON(w, http.StatusOK, calls)
	return nil
}

// handleLiveKitWebhook keeps participants in sync with what LiveKit actually sees
// (app closed, network lost) and ends calls whose room emptied.
func (app *App) handleLiveKitWebhook(w http.ResponseWriter, r *http.Request) error {
	if !app.callsEnabled() {
		return errCallsDisabled
	}
	ev, err := webhook.ReceiveWebhookEvent(r, auth.NewSimpleKeyProvider(app.cfg.LiveKitKey, app.cfg.LiveKitSecret))
	if err != nil {
		return errStatus(http.StatusUnauthorized, "invalid webhook signature")
	}
	if ev.Room == nil || !strings.HasPrefix(ev.Room.Name, callRoomPrefix) {
		w.WriteHeader(http.StatusNoContent)
		return nil
	}
	callID, err := strconv.ParseInt(strings.TrimPrefix(ev.Room.Name, callRoomPrefix), 10, 64)
	if err != nil {
		w.WriteHeader(http.StatusNoContent)
		return nil
	}
	ctx := r.Context()
	app.calls.mu.Lock()
	defer app.calls.mu.Unlock()
	c, err := app.getCall(ctx, callID)
	if errors.Is(err, errNotFound) {
		w.WriteHeader(http.StatusNoContent)
		return nil
	}
	if err != nil {
		return err
	}
	var uid int64
	if ev.Participant != nil {
		uid, _ = strconv.ParseInt(ev.Participant.Identity, 10, 64)
	}
	switch ev.Event {
	case "participant_joined":
		if uid > 0 && c.live() {
			if err := app.addParticipant(ctx, c.ID, uid); err != nil {
				return err
			}
		}
	case "participant_left", "participant_connection_aborted":
		if uid > 0 {
			if err := app.leaveLocked(ctx, c, uid); err != nil {
				return err
			}
		}
	case "room_finished":
		state := callEnded
		if c.State == callRinging {
			state = callMissed
		}
		if err := app.endLocked(ctx, c, state); err != nil {
			return err
		}
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}
