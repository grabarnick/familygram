package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/livekit/protocol/auth"
	"github.com/livekit/protocol/livekit"
	"google.golang.org/protobuf/encoding/protojson"
)

const (
	lkKey    = "testkey"
	lkSecret = "testsecret-testsecret-testsecret"
	lkURL    = "wss://rtc.example.test"
)

func newCallEnv(t *testing.T) *testEnv {
	e := newEnv(t)
	e.app.cfg.LiveKitURL = lkURL
	e.app.cfg.LiveKitKey = lkKey
	e.app.cfg.LiveKitSecret = lkSecret
	return e
}

func (e *testEnv) ws(token string) *websocket.Conn {
	e.t.Helper()
	url := "ws" + strings.TrimPrefix(e.srv.URL, "http") + "/api/ws?token=" + token
	c, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { c.CloseNow() })
	time.Sleep(30 * time.Millisecond) // let the hub register it
	return c
}

func (e *testEnv) directChat(tok string, other int64) Chat {
	var ch Chat
	e.must(200, "POST", "/api/chats", tok, map[string]any{"kind": "direct", "user_id": other}, &ch)
	return ch
}

func lastMessage(e *testEnv, tok string, chatID int64) Message {
	e.t.Helper()
	var msgs []Message
	e.must(200, "GET", fmt.Sprintf("/api/chats/%d/messages", chatID), tok, nil, &msgs)
	if len(msgs) == 0 {
		e.t.Fatal("no messages")
	}
	return msgs[len(msgs)-1]
}

func num(v any) int64 { return int64(v.(float64)) }

func TestCallsDisabled(t *testing.T) {
	e := newEnv(t)
	a, _, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	code, body := e.do("POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{"video": true})
	if code != http.StatusServiceUnavailable || !strings.Contains(string(body), "Звонки не настроены") {
		t.Fatalf("got %d %s", code, body)
	}
	if code, _ := e.do("POST", "/api/calls/1/join", a, nil); code != http.StatusServiceUnavailable {
		t.Fatalf("join: %d", code)
	}
}

func TestCallStartJoinLeave(t *testing.T) {
	e := newCallEnv(t)
	a, b, _, ua, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	wa, wb := e.ws(a), e.ws(b)

	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{"video": true}, &start)
	c := start.Call
	if c.State != callRinging || !c.Video || c.InitiatorID != ua.ID || start.LiveKitURL != lkURL {
		t.Fatalf("start = %+v", start)
	}
	if len(c.ParticipantIDs) != 1 || c.ParticipantIDs[0] != ua.ID {
		t.Fatalf("participants = %v", c.ParticipantIDs)
	}

	// Token: right room, identity and name, signed with our secret.
	v, err := auth.ParseAPIToken(start.Token)
	if err != nil {
		t.Fatal(err)
	}
	_, grants, err := v.Verify(lkSecret)
	if err != nil {
		t.Fatal(err)
	}
	if v.APIKey() != lkKey || grants.Identity != strconv.FormatInt(ua.ID, 10) || grants.Name != ua.DisplayName ||
		grants.Video == nil || !grants.Video.RoomJoin || grants.Video.Room != fmt.Sprintf("call-%d", c.ID) {
		t.Fatalf("grants = %+v video=%+v", grants, grants.Video)
	}

	// Callee gets call.ring; caller does not.
	if d := readEvent(t, wb, "call.ring"); num(d["id"]) != c.ID || d["state"] != callRinging {
		t.Fatalf("call.ring = %v", d)
	}

	// Starting again in the same chat returns the same call (joins it).
	var again CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), b, map[string]bool{"video": false}, &again)
	if again.Call.ID != c.ID || again.Call.State != callActive {
		t.Fatalf("second start = %+v", again.Call)
	}
	if d := readEvent(t, wa, "call.updated"); d["state"] != callActive || len(d["participant_ids"].([]any)) != 2 {
		t.Fatalf("call.updated = %v", d)
	}
	var join CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/calls/%d/join", c.ID), b, nil, &join)
	if join.Call.AnsweredAt == nil || join.Token == "" {
		t.Fatalf("join = %+v", join.Call)
	}

	time.Sleep(20 * time.Millisecond) // a measurable duration
	e.must(204, "POST", fmt.Sprintf("/api/calls/%d/leave", c.ID), b, nil, nil)
	d := readEvent(t, wa, "call.ended")
	if d["state"] != callEnded || d["ended_at"] == nil {
		t.Fatalf("call.ended = %v", d)
	}
	msg := readEvent(t, wa, "message.new")
	if msg["kind"] != "call" || msg["text"] != "Видеозвонок" {
		t.Fatalf("call message = %v", msg)
	}
	ci := msg["call"].(map[string]any)
	if num(ci["id"]) != c.ID || ci["state"] != callEnded || ci["video"] != true || num(ci["duration_ms"]) <= 0 {
		t.Fatalf("call info = %v", ci)
	}

	// Ended call can't be joined; history shows it.
	if code, _ := e.do("POST", fmt.Sprintf("/api/calls/%d/join", c.ID), a, nil); code != http.StatusConflict {
		t.Fatalf("join ended: %d", code)
	}
	var hist []Call
	e.must(200, "GET", "/api/calls", b, nil, &hist)
	if len(hist) != 1 || hist[0].ID != c.ID || hist[0].State != callEnded || len(hist[0].ParticipantIDs) != 2 {
		t.Fatalf("history = %+v", hist)
	}
	// Ordinary messages have no "call" field.
	m := send(e, a, ch.ID, map[string]any{"client_id": "x", "text": "hi"})
	_, raw := e.do("GET", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, nil)
	if m.Call != nil || bytes.Count(raw, []byte(`"call":`)) != 1 {
		t.Fatalf("call field leaked into text messages: %s", raw)
	}
}

func TestCallDeclineDirect(t *testing.T) {
	e := newCallEnv(t)
	a, b, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	wa := e.ws(a)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{}, &start)
	e.must(204, "POST", fmt.Sprintf("/api/calls/%d/decline", start.Call.ID), b, nil, nil)
	if d := readEvent(t, wa, "call.ended"); d["state"] != callDeclined {
		t.Fatalf("call.ended = %v", d)
	}
	m := lastMessage(e, a, ch.ID)
	if m.Kind != "call" || m.Text != "Отклонённый звонок" || m.Call == nil || m.Call.State != callDeclined || m.Call.DurationMs != 0 {
		t.Fatalf("message = %+v call=%+v", m, m.Call)
	}
}

func TestCallGroupDeclineAndLeave(t *testing.T) {
	e := newCallEnv(t)
	a, b, c, _, ub, uc := e.family()
	var g Chat
	e.must(200, "POST", "/api/chats", a, map[string]any{"kind": "group", "title": "Семья", "member_ids": []int64{ub.ID, uc.ID}}, &g)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", g.ID), a, map[string]bool{"video": false}, &start)
	id := start.Call.ID
	// One member declining doesn't end a group call.
	e.must(204, "POST", fmt.Sprintf("/api/calls/%d/decline", id), b, nil, nil)
	cl := *mustCall(e, a, id)
	if cl.State != callRinging {
		t.Fatalf("after decline: %s", cl.State)
	}
	e.must(200, "POST", fmt.Sprintf("/api/calls/%d/join", id), c, nil, nil)
	e.must(204, "POST", fmt.Sprintf("/api/calls/%d/leave", id), a, nil, nil)
	if cl = *mustCall(e, a, id); cl.State != callActive || len(cl.ParticipantIDs) != 1 {
		t.Fatalf("after first leave: %+v", cl)
	}
	e.must(204, "POST", fmt.Sprintf("/api/calls/%d/leave", id), c, nil, nil)
	if cl = *mustCall(e, a, id); cl.State != callEnded {
		t.Fatalf("after last leave: %+v", cl)
	}
	if m := lastMessage(e, b, g.ID); m.Text != "Аудиозвонок" {
		t.Fatalf("message = %+v", m)
	}
}

func mustCall(e *testEnv, tok string, id int64) *Call {
	e.t.Helper()
	var hist []Call
	e.must(200, "GET", "/api/calls", tok, nil, &hist)
	for _, c := range hist {
		if c.ID == id {
			return &c
		}
	}
	e.t.Fatalf("call %d not in history", id)
	return nil
}

func TestCallMissed(t *testing.T) {
	e := newCallEnv(t)
	e.app.calls.ringTimeout = 100 * time.Millisecond
	a, b, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	wb := e.ws(b)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{"video": true}, &start)
	readEvent(t, wb, "call.ring")
	if d := readEvent(t, wb, "call.ended"); d["state"] != callMissed {
		t.Fatalf("call.ended = %v", d)
	}
	if m := readEvent(t, wb, "message.new"); m["text"] != "Пропущенный звонок" {
		t.Fatalf("message = %v", m)
	}
	// The missed call is unread for the callee, read for the caller.
	if chatOf(e, b, ch.ID).Unread != 1 || chatOf(e, a, ch.ID).Unread != 0 {
		t.Fatal("unread counters for missed call")
	}
}

func TestCallAccess(t *testing.T) {
	e := newCallEnv(t)
	a, _, c, ua, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	if code, _ := e.do("POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), c, nil); code != 404 {
		t.Fatalf("outsider start: %d", code)
	}
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, nil, &start)
	for _, op := range []string{"join", "decline", "leave"} {
		if code, _ := e.do("POST", fmt.Sprintf("/api/calls/%d/%s", start.Call.ID, op), c, nil); code != 404 {
			t.Fatalf("outsider %s: %d", op, code)
		}
	}
	var hist []Call
	e.must(200, "GET", "/api/calls", c, nil, &hist)
	if len(hist) != 0 {
		t.Fatalf("outsider sees calls: %+v", hist)
	}
	// Self chat: nobody to call.
	self := e.directChat(a, ua.ID)
	if code, _ := e.do("POST", fmt.Sprintf("/api/chats/%d/call", self.ID), a, nil); code != 400 {
		t.Fatalf("self call: %d", code)
	}
}

func signedWebhook(t *testing.T, e *testEnv, secret string, ev *livekit.WebhookEvent) int {
	t.Helper()
	body, err := protojson.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(body)
	tok, err := auth.NewAccessToken(lkKey, secret).SetSha256(base64.StdEncoding.EncodeToString(sum[:])).
		SetValidFor(time.Minute).ToJWT()
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/livekit/webhook", bytes.NewReader(body))
	req.Header.Set("Authorization", tok)
	req.Header.Set("Content-Type", "application/webhook+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func TestLiveKitWebhook(t *testing.T) {
	e := newCallEnv(t)
	a, b, _, ua, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{"video": true}, &start)
	e.must(200, "POST", fmt.Sprintf("/api/calls/%d/join", start.Call.ID), b, nil, nil)
	room := &livekit.Room{Name: fmt.Sprintf("call-%d", start.Call.ID)}
	left := &livekit.WebhookEvent{Event: "participant_left", Room: room,
		Participant: &livekit.ParticipantInfo{Identity: strconv.FormatInt(ua.ID, 10)}}

	// Wrong secret and missing signature are rejected and change nothing.
	if code := signedWebhook(t, e, "wrong-secret-wrong-secret-wrong", left); code != 401 {
		t.Fatalf("bad signature: %d", code)
	}
	resp, err := http.Post(e.srv.URL+"/api/livekit/webhook", "application/json", strings.NewReader(`{"event":"room_finished"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("unsigned: %d", resp.StatusCode)
	}
	if c := mustCall(e, a, start.Call.ID); c.State != callActive {
		t.Fatalf("state changed by bad webhook: %s", c.State)
	}

	// A real participant_left (app killed) ends the direct call.
	if code := signedWebhook(t, e, lkSecret, left); code != 204 {
		t.Fatalf("webhook: %d", code)
	}
	if c := mustCall(e, a, start.Call.ID); c.State != callEnded {
		t.Fatalf("after participant_left: %s", c.State)
	}
	// Repeats and unknown rooms are harmless.
	if code := signedWebhook(t, e, lkSecret, &livekit.WebhookEvent{Event: "room_finished", Room: room}); code != 204 {
		t.Fatalf("repeat: %d", code)
	}
	if code := signedWebhook(t, e, lkSecret, &livekit.WebhookEvent{Event: "room_finished", Room: &livekit.Room{Name: "other"}}); code != 204 {
		t.Fatalf("other room: %d", code)
	}
	var msgs []Message
	e.must(200, "GET", fmt.Sprintf("/api/chats/%d/messages", ch.ID), a, nil, &msgs)
	calls := 0
	for _, m := range msgs {
		if m.Kind == "call" {
			calls++
		}
	}
	if calls != 1 {
		t.Fatalf("call messages = %d", calls)
	}
}

func TestRecoverCalls(t *testing.T) {
	e := newCallEnv(t)
	a, _, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, nil, &start)
	e.app.calls.mu.Lock()
	e.app.stopRingTimer(start.Call.ID) // simulate a restart: timers are gone
	e.app.calls.mu.Unlock()
	if err := e.app.recoverCalls(context.Background()); err != nil {
		t.Fatal(err)
	}
	if c := mustCall(e, a, start.Call.ID); c.State != callMissed {
		t.Fatalf("recovered state: %s", c.State)
	}
}
