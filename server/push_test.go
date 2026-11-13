package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type pushCall struct {
	Device PushDevice
	Note   PushNote
}

// fakePusher records pushes; tokens listed in gone answer like a deleted app.
type fakePusher struct {
	mu    sync.Mutex
	calls []pushCall
	gone  map[string]bool
	ch    chan pushCall
}

func newFakePusher() *fakePusher {
	return &fakePusher{gone: map[string]bool{}, ch: make(chan pushCall, 16)}
}

func (f *fakePusher) Push(_ context.Context, d PushDevice, n PushNote) error {
	f.mu.Lock()
	f.calls = append(f.calls, pushCall{d, n})
	gone := f.gone[d.Token]
	f.mu.Unlock()
	f.ch <- pushCall{d, n}
	if gone {
		return errPushGone
	}
	return nil
}

// next waits for the next push (sending is asynchronous).
func (f *fakePusher) next(t *testing.T) pushCall {
	t.Helper()
	select {
	case c := <-f.ch:
		return c
	case <-time.After(2 * time.Second):
		t.Fatal("no push sent")
		return pushCall{}
	}
}

func (f *fakePusher) none(t *testing.T) {
	t.Helper()
	select {
	case c := <-f.ch:
		t.Fatalf("unexpected push to %s: %+v", c.Device.Token, c.Note)
	case <-time.After(150 * time.Millisecond):
	}
}

const (
	momPhoneToken = "aa00000000000000000000000000000000000000000000000000000000000001"
	dadPhoneToken = "bb00000000000000000000000000000000000000000000000000000000000002"
)

func (e *testEnv) registerDevice(tok, device string) {
	e.t.Helper()
	e.must(200, "POST", "/api/devices", tok, map[string]any{"platform": "ios", "token": device, "sandbox": true}, nil)
}

func TestPushOnNewMessage(t *testing.T) {
	e := newEnv(t)
	fp := newFakePusher()
	e.app.push = fp
	a, b, c, ua, ub, uc := e.family()
	e.registerDevice(a, dadPhoneToken) // the sender's own phone must stay quiet
	e.registerDevice(b, momPhoneToken)

	ch := e.directChat(a, ub.ID)
	send(e, a, ch.ID, map[string]any{"client_id": "m1", "text": "Привет! Заедешь в субботу?"})
	got := fp.next(t)
	if got.Device.Token != momPhoneToken || !got.Device.Sandbox {
		t.Fatalf("device = %+v", got.Device)
	}
	want := PushNote{Title: ua.DisplayName, Body: "Привет! Заедешь в субботу?", Badge: 1, ChatID: ch.ID, ThreadID: "chat-" + itoa(ch.ID)}
	if got.Note != want {
		t.Fatalf("note = %+v, want %+v", got.Note, want)
	}
	fp.none(t)

	// Group: the chat is the title and the sender's name prefixes the text;
	// the badge counts unread across all of Mom's chats.
	var g Chat
	e.must(200, "POST", "/api/chats", c, map[string]any{"kind": "group", "title": "Семья", "member_ids": []int64{ua.ID, ub.ID}}, &g)
	send(e, c, g.ID, map[string]any{"client_id": "g1", "text": "Ужин в 7"})
	got = fp.next(t)
	if got.Device.Token != momPhoneToken {
		got = fp.next(t) // Dad's phone may come first
	}
	if got.Note.Title != "Семья" || got.Note.Body != uc.DisplayName+": Ужин в 7" || got.Note.Badge != 2 {
		t.Fatalf("group note = %+v", got.Note)
	}
}

func TestPushDeviceLifecycle(t *testing.T) {
	e := newEnv(t)
	fp := newFakePusher()
	e.app.push = fp
	a, b, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)

	e.must(400, "POST", "/api/devices", b, map[string]any{"platform": "android", "token": momPhoneToken}, nil)
	e.must(400, "POST", "/api/devices", b, map[string]any{"platform": "ios", "token": "not-hex"}, nil)
	e.must(401, "POST", "/api/devices", "", map[string]any{"platform": "ios", "token": momPhoneToken}, nil)

	// A dead token (app deleted) is forgotten after the first failed push.
	e.registerDevice(b, momPhoneToken)
	fp.gone[momPhoneToken] = true
	send(e, a, ch.ID, map[string]any{"client_id": "x1", "text": "1"})
	fp.next(t)
	waitFor(t, func() bool { return countDevices(e, momPhoneToken) == 0 })

	// Logging out stops pushes to that phone.
	delete(fp.gone, momPhoneToken)
	e.registerDevice(b, momPhoneToken)
	e.must(200, "POST", "/api/auth/logout", b, nil, nil)
	if n := countDevices(e, momPhoneToken); n != 0 {
		t.Fatalf("device survived logout: %d", n)
	}
	send(e, a, ch.ID, map[string]any{"client_id": "x2", "text": "2"})
	fp.none(t)
}

func TestPushDisabledStillRegisters(t *testing.T) {
	e := newEnv(t) // no pusher configured
	_, b, _, _, _, _ := e.family()
	var res map[string]bool
	e.must(200, "POST", "/api/devices", b, map[string]any{"platform": "ios", "token": momPhoneToken}, &res)
	if res["push"] {
		t.Fatalf("push reported enabled: %v", res)
	}
}

func TestMessagePreview(t *testing.T) {
	long := strings.Repeat("а", pushPreviewLen+20)
	cases := []struct {
		m    Message
		want string
	}{
		{Message{Kind: "text", Text: "  Привет  "}, "Привет"},
		{Message{Kind: "image"}, "📷 Фото"},
		{Message{Kind: "image", Text: "с дачи"}, "📷 Фото, с дачи"},
		{Message{Kind: "video"}, "🎬 Видео"},
		{Message{Kind: "voice"}, "🎤 Голосовое сообщение"},
		{Message{Kind: "file", File: &File{Name: "договор.pdf"}}, "📎 договор.pdf"},
		{Message{Kind: "text", Text: long}, strings.Repeat("а", pushPreviewLen) + "…"},
	}
	for _, c := range cases {
		if got := messagePreview(&c.m); got != c.want {
			t.Errorf("preview(%s %q) = %q, want %q", c.m.Kind, c.m.Text, got, c.want)
		}
	}
}

func TestAPNsPusher(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	p8 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})

	type seen struct {
		path string
		hdr  http.Header
		body map[string]any
		h2   bool
	}
	var mu sync.Mutex
	var reqs []seen
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(b, &body)
		mu.Lock()
		reqs = append(reqs, seen{r.URL.Path, r.Header.Clone(), body, r.ProtoMajor == 2})
		mu.Unlock()
		if strings.HasSuffix(r.URL.Path, "/dead") {
			w.WriteHeader(http.StatusGone)
			_, _ = w.Write([]byte(`{"reason":"Unregistered"}`))
			return
		}
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()

	p, err := newAPNsPusher(p8, "KEY123", "TEAM456", "org.familygram.familygram")
	if err != nil {
		t.Fatal(err)
	}
	p.client = srv.Client()
	p.production, p.sandbox = srv.URL+"/prod", srv.URL+"/sandbox"

	note := PushNote{Title: "Мама", Body: "Привет", Badge: 3, ChatID: 7, ThreadID: "chat-7"}
	if err := p.Push(context.Background(), PushDevice{Token: "abcd", Sandbox: true}, note); err != nil {
		t.Fatal(err)
	}
	err = p.Push(context.Background(), PushDevice{Token: "dead"}, note)
	if !errors.Is(err, errPushGone) {
		t.Fatalf("dead token: %v", err)
	}

	r := reqs[0]
	if r.path != "/sandbox/3/device/abcd" || reqs[1].path != "/prod/3/device/dead" {
		t.Fatalf("paths: %s, %s", r.path, reqs[1].path)
	}
	if !r.h2 {
		t.Fatal("APNs request was not HTTP/2")
	}
	if r.hdr.Get("apns-topic") != "org.familygram.familygram" || r.hdr.Get("apns-push-type") != "alert" {
		t.Fatalf("headers: %v", r.hdr)
	}
	aps := r.body["aps"].(map[string]any)
	alert := aps["alert"].(map[string]any)
	if alert["title"] != "Мама" || alert["body"] != "Привет" || aps["badge"] != float64(3) ||
		aps["thread-id"] != "chat-7" || r.body["chat_id"] != float64(7) {
		t.Fatalf("payload: %v", r.body)
	}

	// Provider token: ES256, signed by our key, with our key and team IDs.
	raw := strings.TrimPrefix(r.hdr.Get("authorization"), "bearer ")
	tok, err := jwt.Parse(raw, func(tk *jwt.Token) (any, error) {
		if tk.Header["kid"] != "KEY123" {
			t.Fatalf("kid = %v", tk.Header["kid"])
		}
		return &key.PublicKey, nil
	}, jwt.WithValidMethods([]string{"ES256"}))
	if err != nil || tok.Claims.(jwt.MapClaims)["iss"] != "TEAM456" {
		t.Fatalf("provider token: %v %v", err, tok)
	}
	// It is reused, not re-signed on every push.
	if reqs[1].hdr.Get("authorization") != r.hdr.Get("authorization") {
		t.Fatal("provider token re-signed for each push")
	}

	if _, err := newAPNsPusher([]byte("junk"), "K", "T", "x"); err == nil {
		t.Fatal("accepted a non-PEM key")
	}
}

func countDevices(e *testEnv, token string) int {
	var n int
	_ = e.app.db.QueryRow(`SELECT COUNT(*) FROM push_devices WHERE token = ?`, token).Scan(&n)
	return n
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if ok() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("condition not met")
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }
