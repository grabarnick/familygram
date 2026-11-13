package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	codeTTL         = 5 * time.Minute
	codeMaxAttempts = 5
	codeResendAfter = 60 * time.Second
	ipWindow        = time.Hour
	ipMaxRequests   = 10
)

var phoneRe = regexp.MustCompile(`^\+[1-9]\d{7,14}$`)

// normalizePhone converts user input to E.164: strips spaces, dashes and
// parentheses; a Russian "8XXXXXXXXXX" becomes "+7XXXXXXXXXX".
func normalizePhone(raw string) (string, error) {
	var b strings.Builder
	for _, r := range strings.TrimSpace(raw) {
		switch {
		case r == ' ' || r == '-' || r == '(' || r == ')' || r == ' ':
		default:
			b.WriteRune(r)
		}
	}
	p := b.String()
	if len(p) == 11 && strings.HasPrefix(p, "8") && isDigits(p) {
		p = "+7" + p[1:]
	}
	if !phoneRe.MatchString(p) {
		return "", errStatus(http.StatusBadRequest, "Неверный номер телефона")
	}
	return p, nil
}

func isDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func randomCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		panic(err)
	}
	return fmt.Sprintf("%06d", n.Int64())
}

func hashToken(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(h[:])
}

func hashCode(phone, code string) string { return hashToken(phone + ":" + code) }

func nowMs() int64 { return time.Now().UnixMilli() }

// ---- per-IP rate limiting for code requests ----

type rateLimiter struct {
	mu     sync.Mutex
	hits   map[string][]time.Time
	window time.Duration
	max    int
}

func newRateLimiter(window time.Duration, max int) *rateLimiter {
	return &rateLimiter{hits: map[string][]time.Time{}, window: window, max: max}
}

// allow records a hit and reports whether it is within the limit.
func (rl *rateLimiter) allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	now := time.Now()
	var kept []time.Time
	for _, t := range rl.hits[key] {
		if now.Sub(t) < rl.window {
			kept = append(kept, t)
		}
	}
	if len(kept) >= rl.max {
		rl.hits[key] = kept
		return false
	}
	rl.hits[key] = append(kept, now)
	return true
}

var codeLimiter = newRateLimiter(ipWindow, ipMaxRequests)

func clientIP(r *http.Request) string {
	// Behind Caddy the real client is in X-Forwarded-For (first hop).
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return strings.TrimSpace(strings.Split(xff, ",")[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---- sessions ----

func requestToken(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	return r.URL.Query().Get("token")
}

func (app *App) userFromRequest(r *http.Request) (*User, error) {
	tok := requestToken(r)
	if tok == "" {
		return nil, errStatus(http.StatusUnauthorized, "unauthorized")
	}
	th := hashToken(tok)
	var uid int64
	err := app.db.QueryRowContext(r.Context(), `SELECT user_id FROM sessions WHERE token_hash = ?`, th).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errStatus(http.StatusUnauthorized, "unauthorized")
	}
	if err != nil {
		return nil, err
	}
	_, _ = app.db.ExecContext(r.Context(), `UPDATE sessions SET last_seen = ? WHERE token_hash = ?`, nowMs(), th)
	return app.getUser(r.Context(), uid)
}

func (app *App) createSession(ctx context.Context, uid int64) (string, error) {
	tok := randomHex(32)
	now := nowMs()
	_, err := app.db.ExecContext(ctx, `INSERT INTO sessions (token_hash, user_id, created_at, last_seen) VALUES (?, ?, ?, ?)`,
		hashToken(tok), uid, now, now)
	return tok, err
}

// ---- allowed phones ----

func (app *App) addAllowedPhone(ctx context.Context, raw, name string, by int64) (string, error) {
	phone, err := normalizePhone(raw)
	if err != nil {
		return "", err
	}
	name = strings.TrimSpace(name)
	if len([]rune(name)) > 64 {
		return "", errStatus(http.StatusBadRequest, "display name too long")
	}
	var addedBy any
	if by > 0 {
		addedBy = by
	}
	_, err = app.db.ExecContext(ctx, `INSERT INTO allowed_phones (phone, display_name, added_by, created_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(phone) DO UPDATE SET display_name = excluded.display_name`, phone, name, addedBy, nowMs())
	return phone, err
}

// phoneAllowed: registered user, allow-listed, or the configured admin phone.
func (app *App) phoneAllowed(ctx context.Context, phone string) (bool, error) {
	if phone == app.cfg.AdminPhone {
		return true, nil
	}
	var one int
	err := app.db.QueryRowContext(ctx, `SELECT 1 FROM users WHERE phone = ? UNION SELECT 1 FROM allowed_phones WHERE phone = ?`, phone, phone).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// ---- handlers ----

func (app *App) handleInfo(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, http.StatusOK, map[string]any{"name": app.cfg.ServerName, "auth": "sms", "calls": app.callsEnabled()})
	return nil
}

// writeRetry answers with a retry_after hint. codeSent marks the per-phone
// cooldown: a valid code is already on its way, so the client can go straight
// to code entry instead of showing an error (unlike the per-IP limit).
func writeRetry(w http.ResponseWriter, status int, msg string, retry int, codeSent bool) {
	w.Header().Set("Retry-After", fmt.Sprint(retry))
	body := map[string]any{"retry_after": retry}
	if msg != "" {
		body["error"] = msg
	}
	if codeSent {
		body["code_sent"] = true
	}
	writeJSON(w, status, body)
}

func (app *App) handleRequestCode(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Phone string `json:"phone"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	phone, err := normalizePhone(req.Phone)
	if err != nil {
		return err
	}
	ctx := r.Context()
	ok, err := app.phoneAllowed(ctx, phone)
	if err != nil {
		return err
	}
	if !ok {
		return errStatus(http.StatusForbidden, "Этот номер не добавлен в семью")
	}

	var sentAt int64
	err = app.db.QueryRowContext(ctx, `SELECT sent_at FROM sms_codes WHERE phone = ?`, phone).Scan(&sentAt)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil {
		if wait := time.UnixMilli(sentAt).Add(codeResendAfter).Sub(time.Now()); wait > 0 {
			writeRetry(w, http.StatusTooManyRequests, "Код уже отправлен, подождите", int(wait.Seconds())+1, true)
			return nil
		}
	}
	if !codeLimiter.allow(clientIP(r)) {
		writeRetry(w, http.StatusTooManyRequests, "Слишком много запросов, попробуйте позже", int(ipWindow.Seconds()), false)
		return nil
	}

	code := randomCode()
	now := time.Now()
	_, err = app.db.ExecContext(ctx, `INSERT INTO sms_codes (phone, code_hash, expires_at, attempts, sent_at) VALUES (?, ?, ?, 0, ?)
		ON CONFLICT(phone) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0, sent_at = excluded.sent_at`,
		phone, hashCode(phone, code), now.Add(codeTTL).UnixMilli(), now.UnixMilli())
	if err != nil {
		return err
	}
	if err := app.sms.Send(ctx, phone, fmt.Sprintf("%s: код %s", app.cfg.ServerName, code)); err != nil {
		log.Printf("sms send to %s failed: %v", phone, err)
		_, _ = app.db.ExecContext(ctx, `DELETE FROM sms_codes WHERE phone = ?`, phone)
		return errStatus(http.StatusBadGateway, "Не удалось отправить SMS, попробуйте позже")
	}
	writeJSON(w, http.StatusOK, map[string]int{"retry_after": int(codeResendAfter.Seconds())})
	return nil
}

type authResponse struct {
	Token string `json:"token"`
	User  *User  `json:"user"`
	IsNew bool   `json:"is_new"`
}

var errBadCode = errStatus(http.StatusUnauthorized, "Неверный или просроченный код")

func (app *App) handleVerify(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	phone, err := normalizePhone(req.Phone)
	if err != nil {
		return err
	}
	code := strings.TrimSpace(req.Code)
	ctx := r.Context()

	tx, err := app.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var codeHash string
	var expires int64
	var attempts int
	err = tx.QueryRow(`SELECT code_hash, expires_at, attempts FROM sms_codes WHERE phone = ?`, phone).Scan(&codeHash, &expires, &attempts)
	if errors.Is(err, sql.ErrNoRows) {
		return errBadCode
	}
	if err != nil {
		return err
	}
	if expires < nowMs() || attempts >= codeMaxAttempts {
		_, _ = tx.Exec(`DELETE FROM sms_codes WHERE phone = ?`, phone)
		_ = tx.Commit()
		return errBadCode
	}
	if subtle.ConstantTimeCompare([]byte(codeHash), []byte(hashCode(phone, code))) != 1 {
		_, _ = tx.Exec(`UPDATE sms_codes SET attempts = attempts + 1 WHERE phone = ?`, phone)
		_ = tx.Commit()
		return errBadCode
	}
	if _, err := tx.Exec(`DELETE FROM sms_codes WHERE phone = ?`, phone); err != nil {
		return err
	}

	isNew := false
	var uid int64
	err = tx.QueryRow(`SELECT id FROM users WHERE phone = ?`, phone).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		var name string
		_ = tx.QueryRow(`SELECT display_name FROM allowed_phones WHERE phone = ?`, phone).Scan(&name)
		if name == "" {
			name = phone
		}
		res, err := tx.Exec(`INSERT INTO users (phone, display_name, is_admin, created_at) VALUES (?, ?, ?, ?)`,
			phone, name, phone == app.cfg.AdminPhone, nowMs())
		if err != nil {
			return err
		}
		uid, _ = res.LastInsertId()
		isNew = true
	} else if err != nil {
		return err
	} else if phone == app.cfg.AdminPhone {
		if _, err := tx.Exec(`UPDATE users SET is_admin = 1 WHERE id = ?`, uid); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	tok, err := app.createSession(ctx, uid)
	if err != nil {
		return err
	}
	u, err := app.getUser(ctx, uid)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, authResponse{Token: tok, User: u, IsNew: isNew})
	return nil
}

func (app *App) handleLogout(w http.ResponseWriter, r *http.Request, u *User) error {
	_, err := app.db.ExecContext(r.Context(), `DELETE FROM sessions WHERE token_hash = ?`, hashToken(requestToken(r)))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	return nil
}

// ---- admin: allowed phones ----

type phoneEntry struct {
	Phone       string `json:"phone"`
	DisplayName string `json:"display_name"`
	Registered  bool   `json:"registered"`
}

func (app *App) handleListPhones(w http.ResponseWriter, r *http.Request, u *User) error {
	if !u.IsAdmin {
		return errForbidden
	}
	rows, err := app.db.QueryContext(r.Context(), `
		SELECT phone, display_name, 1 FROM users
		UNION ALL
		SELECT a.phone, a.display_name, 0 FROM allowed_phones a WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.phone = a.phone)
		ORDER BY 2`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []phoneEntry{}
	for rows.Next() {
		var e phoneEntry
		if err := rows.Scan(&e.Phone, &e.DisplayName, &e.Registered); err != nil {
			return err
		}
		out = append(out, e)
	}
	writeJSON(w, http.StatusOK, out)
	return rows.Err()
}

func (app *App) handleAddPhone(w http.ResponseWriter, r *http.Request, u *User) error {
	if !u.IsAdmin {
		return errForbidden
	}
	var req struct {
		Phone       string `json:"phone"`
		DisplayName string `json:"display_name"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	phone, err := app.addAllowedPhone(r.Context(), req.Phone, req.DisplayName, u.ID)
	if err != nil {
		return err
	}
	var registered bool
	_ = app.db.QueryRowContext(r.Context(), `SELECT 1 FROM users WHERE phone = ?`, phone).Scan(&registered)
	writeJSON(w, http.StatusOK, phoneEntry{Phone: phone, DisplayName: strings.TrimSpace(req.DisplayName), Registered: registered})
	return nil
}

func (app *App) handleDeletePhone(w http.ResponseWriter, r *http.Request, u *User) error {
	if !u.IsAdmin {
		return errForbidden
	}
	raw, _ := url.PathUnescape(r.PathValue("phone"))
	phone, err := normalizePhone(raw)
	if err != nil {
		return err
	}
	if _, err := app.db.ExecContext(r.Context(), `DELETE FROM allowed_phones WHERE phone = ?`, phone); err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	return nil
}
