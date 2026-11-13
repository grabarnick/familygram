//go:build lksmoke

package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/livekit/protocol/livekit"
	"google.golang.org/protobuf/proto"
)

func TestLiveKitSmoke(t *testing.T) {
	e := newEnv(t)
	// Serve on a fixed port so livekit-server can deliver webhooks.
	ln, err := net.Listen("tcp", "127.0.0.1:18080")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(e.app.routes())
	srv.Listener.Close()
	srv.Listener = ln
	srv.Start()
	defer srv.Close()
	e.srv = srv
	e.app.cfg.LiveKitURL = "ws://127.0.0.1:7880"
	e.app.cfg.LiveKitKey = "smokekey"
	e.app.cfg.LiveKitSecret = "smokesecret-smokesecret-smokesecret-01"

	a, b, _, _, ub, _ := e.family()
	ch := e.directChat(a, ub.ID)
	var start CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/chats/%d/call", ch.ID), a, map[string]bool{"video": true}, &start)
	var join CallJoin
	e.must(200, "POST", fmt.Sprintf("/api/calls/%d/join", start.Call.ID), b, nil, &join)

	connect := func(cj CallJoin) *websocket.Conn {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		c, resp, err := websocket.Dial(ctx, cj.LiveKitURL+"/rtc?protocol=15&access_token="+cj.Token, nil)
		if err != nil {
			code := 0
			if resp != nil {
				code = resp.StatusCode
			}
			t.Fatalf("livekit dial: %v (http %d)", err, code)
		}
		c.SetReadLimit(1 << 20)
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				t.Fatalf("livekit read: %v", err)
			}
			var sr livekit.SignalResponse
			if err := proto.Unmarshal(data, &sr); err != nil {
				t.Fatal(err)
			}
			if j := sr.GetJoin(); j != nil {
				t.Logf("joined room %q as %q (%s)", j.Room.GetName(), j.Participant.GetIdentity(), j.Participant.GetName())
				if j.Room.GetName() != fmt.Sprintf("call-%d", start.Call.ID) {
					t.Fatalf("room = %s", j.Room.GetName())
				}
				return c
			}
		}
	}
	ca := connect(start)
	cb := connect(join)
	defer cb.CloseNow()

	// Keep reading in the background so the connections stay healthy.
	go func() {
		ctx := context.Background()
		for {
			if _, _, err := cb.Read(ctx); err != nil {
				return
			}
		}
	}()

	// Caller drops off LiveKit without calling /leave: the webhook must end the call.
	ca.CloseNow()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if c := mustCall(e, a, start.Call.ID); c.State == callEnded {
			t.Logf("call ended via LiveKit webhook: %+v", c)
			m := lastMessage(e, a, ch.ID)
			if m.Kind != "call" || m.Call == nil || m.Call.DurationMs <= 0 {
				t.Fatalf("call message = %+v", m)
			}
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	_ = http.StatusOK
	t.Fatal("call not ended by webhook within 20s")
}
