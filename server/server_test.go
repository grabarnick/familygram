package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const adminPhone = "+79990000001"

type fakeSMS struct {
	mu    sync.Mutex
	codes map[string]string
}

func (f *fakeSMS) Send(_ context.Context, phone, text string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.codes[phone] = text[len(text)-6:]
	return nil
}

func (f *fakeSMS) code(phone string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.codes[phone]
}

type testEnv struct {
	t   *testing.T
	app *App
	srv *httptest.Server
	sms *fakeSMS
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	dir := t.TempDir()
	db, err := openDB(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	sms := &fakeSMS{codes: map[string]string{}}
	cfg := Config{DataDir: dir, WebDir: filepath.Join(dir, "web"), ServerName: "Familygram",
		AdminPhone: adminPhone, MaxUploadBytes: 1 << 20}
	if err := os.MkdirAll(filepath.Join(dir, "files"), 0o755); err != nil {
		t.Fatal(err)
	}
	app := &App{cfg: cfg, db: db, hub: newHub(), sms: sms}
	codeLimiter = newRateLimiter(ipWindow, 1000)
	srv := httptest.NewServer(app.routes())
	t.Cleanup(srv.Close)
	return &testEnv{t: t, app: app, srv: srv, sms: sms}
}

func (e *testEnv) do(method, path, token string, body any) (int, []byte) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func (e *testEnv) must(status int, method, path, token string, body, out any) {
	e.t.Helper()
	got, b := e.do(method, path, token, body)
	if got != status {
		e.t.Fatalf("%s %s: status %d, want %d: %s", method, path, got, status, b)
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			e.t.Fatalf("%s %s: decode: %v: %s", method, path, err, b)
		}
	}
}

// login runs the full SMS flow and returns token + user.
func (e *testEnv) login(phone string) (string, *User, bool) {
	e.t.Helper()
	// Allow immediate re-requests in tests.
	_, _ = e.app.db.Exec(`UPDATE sms_codes SET sent_at = 0 WHERE phone = ?`, phone)
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": phone}, nil)
	var res authResponse
	e.must(200, "POST", "/api/auth/verify", "", map[string]string{"phone": phone, "code": e.sms.code(phone)}, &res)
	return res.Token, res.User, res.IsNew
}

func (e *testEnv) allow(adminTok, phone, name string) {
	e.t.Helper()
	e.must(200, "POST", "/api/phones", adminTok, map[string]string{"phone": phone, "display_name": name}, nil)
}

// family: admin + two members, all logged in.
func (e *testEnv) family() (a, b, c string, ua, ub, uc *User) {
	a, ua, _ = e.login(adminPhone)
	e.allow(a, "+79990000002", "Мама")
	e.allow(a, "+79990000003", "Папа")
	b, ub, _ = e.login("+79990000002")
	c, uc, _ = e.login("+79990000003")
	return
}

func TestNormalizePhone(t *testing.T) {
	cases := []struct {
		in, want string
		ok       bool
	}{
		{"+7 (999) 123-45-67", "+79991234567", true},
		{"89991234567", "+79991234567", true},
		{"+1 415 555 0100", "+14155550100", true},
		{"9991234567", "", false},
		{"+0123456789", "", false},
		{"+7999abc4567", "", false},
		{"", "", false},
	}
	for _, c := range cases {
		got, err := normalizePhone(c.in)
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("normalizePhone(%q) = %q, %v; want %q ok=%v", c.in, got, err, c.want, c.ok)
		}
	}
}

func TestAuthFlow(t *testing.T) {
	e := newEnv(t)
	var info map[string]any
	e.must(200, "GET", "/api/info", "", nil, &info)
	if info["auth"] != "sms" || info["name"] != "Familygram" || info["calls"] != false {
		t.Fatalf("info = %v", info)
	}

	// Strangers get no SMS.
	st, body := e.do("POST", "/api/auth/request-code", "", map[string]string{"phone": "+79995550000"})
	if st != 403 || !strings.Contains(string(body), "не добавлен") {
		t.Fatalf("stranger: %d %s", st, body)
	}
	if e.sms.code("+79995550000") != "" {
		t.Fatal("SMS sent to stranger")
	}
	st, _ = e.do("POST", "/api/auth/request-code", "", map[string]string{"phone": "12"})
	if st != 400 {
		t.Fatalf("bad phone: %d", st)
	}

	// Admin: first login creates an admin user. "8..." input is normalized.
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": "8 999 000-00-01"}, nil)
	// Resend within 60s -> 429 with retry_after.
	var retry map[string]any
	e.must(429, "POST", "/api/auth/request-code", "", map[string]string{"phone": adminPhone}, &retry)
	if ra, _ := retry["retry_after"].(float64); ra <= 0 || ra > 60 {
		t.Fatalf("retry_after = %v", retry)
	}
	// The client relies on this flag to open code entry rather than show an error.
	if retry["code_sent"] != true {
		t.Fatalf("code_sent = %v", retry)
	}
	e.must(401, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": "000000x"}, nil)
	var res authResponse
	e.must(200, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": e.sms.code(adminPhone)}, &res)
	if !res.IsNew || !res.User.IsAdmin || res.User.Phone != adminPhone || res.Token == "" {
		t.Fatalf("admin verify = %+v", res)
	}
	admin := res.Token
	// Code is single-use.
	e.must(401, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": e.sms.code(adminPhone)}, nil)

	// Second login: not new.
	if _, u, isNew := e.login(adminPhone); isNew || !u.IsAdmin {
		t.Fatalf("second login isNew=%v admin=%v", isNew, u.IsAdmin)
	}

	// Admin adds a phone; that user gets the configured name.
	e.allow(admin, "8 (999) 000-00-02", "Мама")
	mama, u, isNew := e.login("+79990000002")
	if !isNew || u.DisplayName != "Мама" || u.IsAdmin {
		t.Fatalf("mama = %+v new=%v", u, isNew)
	}
	e.must(403, "GET", "/api/phones", mama, nil, nil)
	e.must(403, "POST", "/api/phones", mama, map[string]string{"phone": "+79990000009"}, nil)

	e.allow(admin, "+79990000003", "")
	var phones []phoneEntry
	e.must(200, "GET", "/api/phones", admin, nil, &phones)
	reg := map[string]bool{}
	for _, p := range phones {
		reg[p.Phone] = p.Registered
	}
	if len(phones) != 3 || !reg[adminPhone] || !reg["+79990000002"] || reg["+79990000003"] {
		t.Fatalf("phones = %+v", phones)
	}
	e.must(200, "DELETE", "/api/phones/+79990000003", admin, nil, nil)
	st, _ = e.do("POST", "/api/auth/request-code", "", map[string]string{"phone": "+79990000003"})
	if st != 403 {
		t.Fatalf("removed phone: %d", st)
	}

	// Profile update, then logout invalidates the token.
	var me User
	e.must(200, "PATCH", "/api/me", mama, map[string]string{"display_name": "Мамочка"}, &me)
	if me.DisplayName != "Мамочка" {
		t.Fatalf("me = %+v", me)
	}
	e.must(200, "POST", "/api/auth/logout", mama, nil, nil)
	e.must(401, "GET", "/api/me", mama, nil, nil)
	e.must(401, "GET", "/api/me", "", nil, nil)
}

func TestCodeAttemptsExhausted(t *testing.T) {
	e := newEnv(t)
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": adminPhone}, nil)
	for i := 0; i < codeMaxAttempts; i++ {
		e.must(401, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": "999999x"}, nil)
	}
	e.must(401, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": e.sms.code(adminPhone)}, nil)
}

func TestCodeExpired(t *testing.T) {
	e := newEnv(t)
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": adminPhone}, nil)
	_, _ = e.app.db.Exec(`UPDATE sms_codes SET expires_at = 1`)
	e.must(401, "POST", "/api/auth/verify", "", map[string]string{"phone": adminPhone, "code": e.sms.code(adminPhone)}, nil)
}

func TestIPRateLimit(t *testing.T) {
	e := newEnv(t)
	a, _, _ := e.login(adminPhone)
	for i := 2; i <= 4; i++ {
		e.allow(a, fmt.Sprintf("+7999000000%d", i), "")
	}
	codeLimiter = newRateLimiter(ipWindow, 2)
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": "+79990000002"}, nil)
	e.must(200, "POST", "/api/auth/request-code", "", map[string]string{"phone": "+79990000003"}, nil)
	e.must(429, "POST", "/api/auth/request-code", "", map[string]string{"phone": "+79990000004"}, nil)
}

func TestDirectChats(t *testing.T) {
	e := newEnv(t)
	a, b, _, ua, ub, _ := e.family()

	var c1, c2, c3 Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ub.ID}, &c1)
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ub.ID}, &c2)
	e.must(200, "POST", "/api/chats", b, map[string]any{"kind": "direct", "user_id": ua.ID}, &c3)
	if c1.ID != c2.ID || c1.ID != c3.ID {
		t.Fatalf("direct chat not deduped: %d %d %d", c1.ID, c2.ID, c3.ID)
	}
	if c1.Title != "Мама" || c3.Title != ua.DisplayName || len(c1.MemberIDs) != 2 {
		t.Fatalf("titles: %q / %q members=%v", c1.Title, c3.Title, c1.MemberIDs)
	}

	var self Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ua.ID}, &self)
	if self.Title != "Избранное" || len(self.MemberIDs) != 1 {
		t.Fatalf("self chat = %+v", self)
	}
	e.must(400, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": 999}, nil)
	e.must(400, "POST", "/api/chats", a, map[string]any{"kind": "group", "title": " "}, nil)
	e.must(400, "POST", "/api/chats", a, map[string]any{"kind": "channel"}, nil)

	var g Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "group", "title": "Семья", "member_ids": []int64{ub.ID, ub.ID}}, &g)
	if g.Kind != "group" || g.Title != "Семья" || len(g.MemberIDs) != 2 {
		t.Fatalf("group = %+v", g)
	}
	var list []Chat
	e.must(200, "GET", "/api/chats", b, nil, &list)
	if len(list) != 2 {
		t.Fatalf("b sees %d chats", len(list))
	}
}

func send(e *testEnv, tok string, chatID int64, body map[string]any) Message {
	e.t.Helper()
	var m Message
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/messages", chatID), tok, body, &m)
	return m
}

func TestMessages(t *testing.T) {
	e := newEnv(t)
	a, b, c, _, ub, _ := e.family()
	var ch Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ub.ID}, &ch)

	var ids []int64
	for i := 0; i < 120; i++ {
		m := send(e, a, ch.ID, map[string]any{"client_id": fmt.Sprintf("c%d", i), "text": fmt.Sprintf("msg %d", i)})
		if m.Kind != "text" || m.ChatID != ch.ID {
			t.Fatalf("bad message %+v", m)
		}
		ids = append(ids, m.ID)
	}

	// Idempotent retry.
	dup := send(e, a, ch.ID, map[string]any{"client_id": "c5", "text": "different"})
	if dup.ID != ids[5] || dup.Text != "msg 5" {
		t.Fatalf("idempotency broken: %+v", dup)
	}

	var page []Message
	e.must(200, "GET", fmt.Sprintf("/api/chats/%d/messages", ch.ID), b, nil, &page)
	if len(page) != 50 || page[0].ID != ids[70] || page[49].ID != ids[119] {
		t.Fatalf("page1 len=%d first=%d last=%d", len(page), page[0].ID, page[len(page)-1].ID)
	}
	e.must(200, "GET", fmt.Sprintf("/api/chats/%d/messages?before=%d&limit=100", ch.ID, ids[70]), b, nil, &page)
	if len(page) != 70 || page[0].ID != ids[0] || page[69].ID != ids[69] {
		t.Fatalf("page2 len=%d", len(page))
	}

	// Replies, validation, membership.
	r := send(e, b, ch.ID, map[string]any{"client_id": "r1", "text": "ответ", "reply_to_id": ids[3]})
	if r.ReplyToID == nil || *r.ReplyToID != ids[3] {
		t.Fatalf("reply = %+v", r)
	}
	var other Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "group", "title": "x"}, &other)
	otherMsg := send(e, a, other.ID, map[string]any{"client_id": "o1", "text": "hi"})
	e.must(400, "POST", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, map[string]any{"client_id": "r2", "text": "x", "reply_to_id": otherMsg.ID}, nil)
	e.must(400, "POST", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, map[string]any{"client_id": "e1", "text": "   "}, nil)
	e.must(400, "POST", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, map[string]any{"text": "no client id"}, nil)
	e.must(404, "POST", fmt.Sprintf("/api/chats/%d/messages", ch.ID), c, map[string]any{"client_id": "x", "text": "intruder"}, nil)
	e.must(404, "GET", fmt.Sprintf("/api/chats/%d/messages", ch.ID), c, nil, nil)

	// Delete: only the sender.
	e.must(403, "DELETE", fmt.Sprintf("/api/messages/%d", ids[0]), b, nil, nil)
	e.must(200, "DELETE", fmt.Sprintf("/api/messages/%d", ids[0]), a, nil, nil)
	e.must(200, "GET", fmt.Sprintf("/api/chats/%d/messages?limit=1&before=%d", ch.ID, ids[1]), a, nil, &page)
	if !page[0].Deleted || page[0].Text != "" {
		t.Fatalf("deleted = %+v", page[0])
	}
}

func chatOf(e *testEnv, tok string, id int64) Chat {
	e.t.Helper()
	var list []Chat
	e.must(200, "GET", "/api/chats", tok, nil, &list)
	for _, c := range list {
		if c.ID == id {
			return c
		}
	}
	e.t.Fatalf("chat %d not found", id)
	return Chat{}
}

func TestUnreadAndRead(t *testing.T) {
	e := newEnv(t)
	a, b, _, ua, ub, _ := e.family()
	var ch Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "group", "title": "Семья", "member_ids": []int64{ub.ID}}, &ch)

	var last Message
	for i := 0; i < 3; i++ {
		last = send(e, b, ch.ID, map[string]any{"client_id": fmt.Sprint(i), "text": "hi"})
	}
	ca := chatOf(e, a, ch.ID)
	if ca.Unread != 3 || ca.LastMessage == nil || ca.LastMessage.ID != last.ID || ca.OthersReadID != last.ID {
		t.Fatalf("a view = unread %d last %+v others_read %d", ca.Unread, ca.LastMessage, ca.OthersReadID)
	}
	if cb := chatOf(e, b, ch.ID); cb.Unread != 0 || cb.LastReadID != last.ID || cb.OthersReadID != 0 {
		t.Fatalf("b view = %+v", cb)
	}

	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/read", ch.ID), a, map[string]int64{"message_id": last.ID + 1000}, nil)
	if ca = chatOf(e, a, ch.ID); ca.Unread != 0 || ca.LastReadID != last.ID {
		t.Fatalf("after read a = %+v", ca)
	}
	if cb := chatOf(e, b, ch.ID); cb.OthersReadID != last.ID {
		t.Fatalf("b others_read = %d", cb.OthersReadID)
	}
	_ = ua
}

func upload(e *testEnv, tok, name, ctype string, data []byte, fields map[string]string) (int, File) {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range fields {
		_ = mw.WriteField(k, v)
	}
	h := make(map[string][]string)
	h["Content-Disposition"] = []string{fmt.Sprintf(`form-data; name="file"; filename="%s"`, name)}
	if ctype != "" {
		h["Content-Type"] = []string{ctype}
	}
	pw, _ := mw.CreatePart(h)
	_, _ = pw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/files", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	var f File
	b, _ := io.ReadAll(resp.Body)
	_ = json.Unmarshal(b, &f)
	return resp.StatusCode, f
}

func get(e *testEnv, path string, hdr map[string]string) (*http.Response, []byte) {
	e.t.Helper()
	req, _ := http.NewRequest("GET", e.srv.URL+path, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func TestFiles(t *testing.T) {
	e := newEnv(t)
	a, b, c, _, ub, _ := e.family()

	png := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{7}, 2000)...)
	st, f := upload(e, a, "фото.png", "", png, map[string]string{"width": "640", "height": "480"})
	if st != 200 || f.Mime != "image/png" || f.Size != int64(len(png)) || f.Width != 640 || f.Height != 480 || len(f.ID) != 32 {
		t.Fatalf("upload = %d %+v", st, f)
	}

	// Uploader can fetch; others can't until it's posted in their chat.
	resp, body := get(e, "/api/files/"+f.ID+"?token="+a, nil)
	if resp.StatusCode != 200 || !bytes.Equal(body, png) || !strings.HasPrefix(resp.Header.Get("Content-Disposition"), "inline") {
		t.Fatalf("download: %d %q", resp.StatusCode, resp.Header.Get("Content-Disposition"))
	}
	if resp, _ := get(e, "/api/files/"+f.ID+"?token="+b, nil); resp.StatusCode != 404 {
		t.Fatalf("b before post: %d", resp.StatusCode)
	}

	var ch Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ub.ID}, &ch)
	m := send(e, a, ch.ID, map[string]any{"client_id": "f1", "file_id": f.ID, "text": "дача"})
	if m.Kind != "image" || m.File == nil || m.File.ID != f.ID {
		t.Fatalf("image message = %+v", m)
	}
	resp, body = get(e, "/api/files/"+f.ID, map[string]string{"Authorization": "Bearer " + b, "Range": "bytes=0-7"})
	if resp.StatusCode != 206 || string(body) != "\x89PNG\r\n\x1a\n" {
		t.Fatalf("range: %d %q", resp.StatusCode, body)
	}
	if resp, _ := get(e, "/api/files/"+f.ID+"?token="+c, nil); resp.StatusCode != 404 {
		t.Fatalf("outsider: %d", resp.StatusCode)
	}
	// Outsider also can't attach someone else's file.
	var cc Chat
	e.must(200, "POST", "/api/chats", c, map[string]any{"kind": "group", "title": "c"}, &cc)
	e.must(400, "POST", fmt.Sprintf("/api/chats/%d/messages", cc.ID), c, map[string]any{"client_id": "steal", "file_id": f.ID}, nil)

	// Voice + generic file kinds; attachment disposition for non-media.
	st, v := upload(e, b, "voice.m4a", "audio/mp4", []byte("fake-audio"), map[string]string{"duration_ms": "4200"})
	if st != 200 || v.DurationMs != 4200 {
		t.Fatalf("voice upload %d %+v", st, v)
	}
	vm := send(e, b, ch.ID, map[string]any{"client_id": "v1", "file_id": v.ID, "kind": "voice"})
	if vm.Kind != "voice" {
		t.Fatalf("voice kind = %s", vm.Kind)
	}
	_, pdf := upload(e, a, "doc.pdf", "", []byte("%PDF-1.4 hello"), nil)
	pm := send(e, a, ch.ID, map[string]any{"client_id": "p1", "file_id": pdf.ID})
	if pm.Kind != "file" || pdf.Mime != "application/pdf" {
		t.Fatalf("pdf = %+v / %+v", pdf, pm)
	}
	resp, _ = get(e, "/api/files/"+pdf.ID+"?token="+b, nil)
	if !strings.HasPrefix(resp.Header.Get("Content-Disposition"), "attachment") {
		t.Fatalf("pdf disposition %q", resp.Header.Get("Content-Disposition"))
	}
	e.must(400, "POST", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, map[string]any{"client_id": "k", "file_id": pdf.ID, "kind": "sticker"}, nil)

	// Size limit (1 MiB in tests).
	if st, _ := upload(e, a, "big.bin", "", make([]byte, 2<<20), nil); st != 413 {
		t.Fatalf("big upload status %d", st)
	}
	if resp, _ := get(e, "/api/files/nothex?token="+a, nil); resp.StatusCode != 404 {
		t.Fatalf("bad id: %d", resp.StatusCode)
	}
}

func readEvent(t *testing.T, conn *websocket.Conn, want string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %s: %v", want, err)
		}
		var env struct {
			Type string         `json:"type"`
			Data map[string]any `json:"data"`
		}
		if err := json.Unmarshal(data, &env); err != nil {
			t.Fatal(err)
		}
		if env.Type == want {
			return env.Data
		}
	}
}

func TestWebSocket(t *testing.T) {
	e := newEnv(t)
	a, b, _, ua, ub, _ := e.family()
	wsURL := "ws" + strings.TrimPrefix(e.srv.URL, "http") + "/api/ws?token="

	ctx := context.Background()
	if _, resp, err := websocket.Dial(ctx, wsURL+"bad", nil); err == nil || resp.StatusCode != 401 {
		t.Fatalf("bad token ws should be 401")
	}
	ca, _, err := websocket.Dial(ctx, wsURL+a, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ca.CloseNow()
	cb, _, err := websocket.Dial(ctx, wsURL+b, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cb.CloseNow()
	time.Sleep(50 * time.Millisecond) // let both register in the hub

	var ch Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "direct", "user_id": ub.ID}, &ch)
	if d := readEvent(t, cb, "chat.new"); int64(d["chat_id"].(float64)) != ch.ID {
		t.Fatalf("chat.new = %v", d)
	}

	m := send(e, b, ch.ID, map[string]any{"client_id": "w1", "text": "привет"})
	d := readEvent(t, ca, "message.new")
	if int64(d["id"].(float64)) != m.ID || d["text"] != "привет" || int64(d["sender_id"].(float64)) != ub.ID {
		t.Fatalf("message.new = %v", d)
	}

	if err := cb.Write(ctx, websocket.MessageText, []byte(fmt.Sprintf(`{"type":"typing","data":{"chat_id":%d}}`, ch.ID))); err != nil {
		t.Fatal(err)
	}
	if d := readEvent(t, ca, "typing"); int64(d["user_id"].(float64)) != ub.ID {
		t.Fatalf("typing = %v", d)
	}

	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/read", ch.ID), a, map[string]int64{"message_id": m.ID}, nil)
	if d := readEvent(t, cb, "chat.read"); int64(d["user_id"].(float64)) != ua.ID {
		t.Fatalf("chat.read = %v", d)
	}
	e.must(200, "DELETE", fmt.Sprintf("/api/messages/%d", m.ID), b, nil, nil)
	if d := readEvent(t, ca, "message.deleted"); int64(d["id"].(float64)) != m.ID {
		t.Fatalf("message.deleted = %v", d)
	}
}

func TestStaticAndCORS(t *testing.T) {
	e := newEnv(t)
	resp, body := get(e, "/some/spa/route", nil)
	if resp.StatusCode != 200 || !strings.Contains(string(body), "Web client is not installed") {
		t.Fatalf("static fallback: %d %s", resp.StatusCode, body)
	}
	if resp, _ := get(e, "/api/nope", nil); resp.StatusCode != 404 {
		t.Fatalf("unknown api: %d", resp.StatusCode)
	}
	req, _ := http.NewRequest("OPTIONS", e.srv.URL+"/api/chats", nil)
	req.Header.Set("Origin", "http://localhost:5000")
	r2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	r2.Body.Close()
	if r2.StatusCode != 204 || r2.Header.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("cors preflight: %d", r2.StatusCode)
	}
}
