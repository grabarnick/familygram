package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
)

// ---- push notifications ----
//
// The server pushes straight to Apple (APNs) with a token-based .p8 key, so
// there is no Firebase or other third party in between. Android (FCM) can be
// added as another Pusher later.

// PushDevice is one phone registered for notifications.
type PushDevice struct {
	Token    string
	Platform string // "ios"
	Sandbox  bool   // development-signed build → APNs sandbox
}

// PushNote is what the phone shows for a new message.
type PushNote struct {
	Title    string
	Body     string
	Badge    int    // total unread for the recipient
	ChatID   int64  // the app opens this chat when the notification is tapped
	ThreadID string // groups a chat's notifications together
}

// errPushGone means the token is dead (app deleted, push disabled…): forget it.
var errPushGone = errors.New("push token no longer valid")

type Pusher interface {
	Push(ctx context.Context, d PushDevice, n PushNote) error
}

// ---- device registration ----

func (app *App) handleRegisterDevice(w http.ResponseWriter, r *http.Request, u *User) error {
	var req struct {
		Platform string `json:"platform"`
		Token    string `json:"token"`
		Sandbox  bool   `json:"sandbox"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	if req.Platform != "ios" {
		return errStatus(http.StatusBadRequest, "unsupported platform")
	}
	tok := strings.ToLower(strings.TrimSpace(req.Token))
	if b, err := hex.DecodeString(tok); err != nil || len(b) < 16 || len(b) > 100 {
		return errStatus(http.StatusBadRequest, "invalid token")
	}
	// A token belongs to one phone; if someone else signed in on it before,
	// it now follows the current session.
	_, err := app.db.ExecContext(r.Context(), `INSERT INTO push_devices (token, user_id, session_hash, platform, sandbox, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, session_hash = excluded.session_hash,
			platform = excluded.platform, sandbox = excluded.sandbox, updated_at = excluded.updated_at`,
		tok, u.ID, hashToken(requestToken(r)), req.Platform, req.Sandbox, nowMs())
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true, "push": app.push != nil})
	return nil
}

func (app *App) pushDevices(ctx context.Context, uid int64) ([]PushDevice, error) {
	rows, err := app.db.QueryContext(ctx, `SELECT token, platform, sandbox FROM push_devices WHERE user_id = ?`, uid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PushDevice
	for rows.Next() {
		var d PushDevice
		if err := rows.Scan(&d.Token, &d.Platform, &d.Sandbox); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// unreadTotal is the app badge: unread messages from others across all chats.
func (app *App) unreadTotal(ctx context.Context, uid int64) (int, error) {
	var n int
	err := app.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM messages m
		JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?
		WHERE m.id > cm.last_read_id AND m.sender_id <> ? AND m.deleted = 0`, uid, uid).Scan(&n)
	return n, err
}

// ---- new message → push ----

const pushPreviewLen = 180

// messagePreview is the notification text for a message.
func messagePreview(m *Message) string {
	caption := strings.TrimSpace(m.Text)
	withCaption := func(label string) string {
		if caption == "" {
			return label
		}
		return label + ", " + caption
	}
	var s string
	switch m.Kind {
	case "image":
		s = withCaption("📷 Фото")
	case "video":
		s = withCaption("🎬 Видео")
	case "voice":
		s = "🎤 Голосовое сообщение"
	case "file":
		name := "Файл"
		if m.File != nil && m.File.Name != "" {
			name = m.File.Name
		}
		s = withCaption("📎 " + name)
	default:
		s = caption
	}
	if utf8.RuneCountInString(s) > pushPreviewLen {
		s = string([]rune(s)[:pushPreviewLen]) + "…"
	}
	return s
}

// notifyNewMessage pushes m to every other chat member's phones. It runs in
// the background so sending a message never waits for Apple.
func (app *App) notifyNewMessage(m *Message, sender *User) {
	if app.push == nil || m.Kind == "call" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := app.pushMessage(ctx, m, sender); err != nil {
			log.Printf("push: message %d: %v", m.ID, err)
		}
	}()
}

func (app *App) pushMessage(ctx context.Context, m *Message, sender *User) error {
	var kind, title string
	if err := app.db.QueryRowContext(ctx, `SELECT kind, title FROM chats WHERE id = ?`, m.ChatID).Scan(&kind, &title); err != nil {
		return err
	}
	members, err := app.chatMemberIDs(ctx, m.ChatID)
	if err != nil {
		return err
	}
	note := PushNote{ChatID: m.ChatID, ThreadID: fmt.Sprintf("chat-%d", m.ChatID), Body: messagePreview(m)}
	if kind == "group" {
		note.Title = title
		note.Body = sender.DisplayName + ": " + note.Body
	} else {
		note.Title = sender.DisplayName
	}
	for _, uid := range members {
		if uid == sender.ID {
			continue
		}
		devs, err := app.pushDevices(ctx, uid)
		if err != nil {
			return err
		}
		if len(devs) == 0 {
			continue
		}
		n := note
		if n.Badge, err = app.unreadTotal(ctx, uid); err != nil {
			return err
		}
		for _, d := range devs {
			err := app.push.Push(ctx, d, n)
			if errors.Is(err, errPushGone) {
				_, _ = app.db.ExecContext(ctx, `DELETE FROM push_devices WHERE token = ?`, d.Token)
			} else if err != nil {
				log.Printf("push: user %d: %v", uid, err)
			}
		}
	}
	return nil
}

// ---- Apple Push Notification service ----

const (
	apnsProduction = "https://api.push.apple.com"
	apnsSandbox    = "https://api.sandbox.push.apple.com"
	// Apple rejects provider tokens older than an hour and throttles
	// re-signing more often than every 20 minutes.
	apnsTokenTTL = 40 * time.Minute
)

type apnsPusher struct {
	keyID, teamID, topic string
	key                  *ecdsa.PrivateKey
	client               *http.Client
	production, sandbox  string // base URLs; overridable in tests

	mu      sync.Mutex
	jwt     string
	jwtTime time.Time
}

// newAPNsPusher reads the .p8 key from App Store Connect / Certificates,
// Identifiers & Profiles → Keys (with "Apple Push Notifications service").
func newAPNsPusher(keyPEM []byte, keyID, teamID, topic string) (*apnsPusher, error) {
	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, errors.New("APNs key: not a PEM (.p8) file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("APNs key: %w", err)
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("APNs key: not an EC key")
	}
	if keyID == "" || teamID == "" || topic == "" {
		return nil, errors.New("APNs: key id, team id and topic are required")
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ForceAttemptHTTP2 = true // APNs speaks HTTP/2 only
	return &apnsPusher{
		keyID: keyID, teamID: teamID, topic: topic, key: ec,
		client:     &http.Client{Transport: tr, Timeout: 15 * time.Second},
		production: apnsProduction, sandbox: apnsSandbox,
	}, nil
}

func (p *apnsPusher) providerToken(now time.Time) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.jwt != "" && now.Sub(p.jwtTime) < apnsTokenTTL {
		return p.jwt, nil
	}
	t := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": p.teamID, "iat": now.Unix()})
	t.Header["kid"] = p.keyID
	s, err := t.SignedString(p.key)
	if err != nil {
		return "", err
	}
	p.jwt, p.jwtTime = s, now
	return s, nil
}

func (p *apnsPusher) resetToken() {
	p.mu.Lock()
	p.jwt = ""
	p.mu.Unlock()
}

func apnsPayload(n PushNote) ([]byte, error) {
	aps := map[string]any{
		"alert": map[string]string{"title": n.Title, "body": n.Body},
		"sound": "default",
		"badge": n.Badge,
	}
	if n.ThreadID != "" {
		aps["thread-id"] = n.ThreadID
	}
	return json.Marshal(map[string]any{"aps": aps, "chat_id": n.ChatID})
}

func (p *apnsPusher) Push(ctx context.Context, d PushDevice, n PushNote) error {
	body, err := apnsPayload(n)
	if err != nil {
		return err
	}
	base := p.production
	if d.Sandbox {
		base = p.sandbox
	}
	jwtTok, err := p.providerToken(time.Now())
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+d.Token, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+jwtTok)
	req.Header.Set("apns-topic", p.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(24*time.Hour).Unix()))
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	var e struct {
		Reason string `json:"reason"`
	}
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	_ = json.Unmarshal(raw, &e)
	switch {
	case resp.StatusCode == http.StatusGone,
		e.Reason == "BadDeviceToken", e.Reason == "Unregistered", e.Reason == "DeviceTokenNotForTopic":
		return fmt.Errorf("%w: %s", errPushGone, e.Reason)
	case e.Reason == "ExpiredProviderToken", e.Reason == "InvalidProviderToken":
		p.resetToken()
	}
	return fmt.Errorf("APNs %d %s", resp.StatusCode, e.Reason)
}
