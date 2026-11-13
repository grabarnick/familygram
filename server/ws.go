package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	wsPingInterval = 25 * time.Second
	wsSendBuffer   = 128
)

type wsConn struct {
	send chan []byte
	once sync.Once
	done chan struct{}
}

func (c *wsConn) close() { c.once.Do(func() { close(c.done) }) }

type Hub struct {
	mu    sync.RWMutex
	conns map[int64]map[*wsConn]struct{}
}

func newHub() *Hub { return &Hub{conns: map[int64]map[*wsConn]struct{}{}} }

func (h *Hub) add(uid int64, c *wsConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[uid] == nil {
		h.conns[uid] = map[*wsConn]struct{}{}
	}
	h.conns[uid][c] = struct{}{}
}

func (h *Hub) remove(uid int64, c *wsConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns[uid], c)
	if len(h.conns[uid]) == 0 {
		delete(h.conns, uid)
	}
}

type wsEnvelope struct {
	Type string `json:"type"`
	Data any    `json:"data"`
}

// send delivers an event to every connection of a user. A connection that
// can't keep up is dropped; the client reconnects and refetches.
func (h *Hub) send(uid int64, typ string, data any) {
	b, err := json.Marshal(wsEnvelope{Type: typ, Data: data})
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.conns[uid] {
		select {
		case c.send <- b:
		default:
			c.close()
		}
	}
}

func (app *App) handleWS(w http.ResponseWriter, r *http.Request, u *User) error {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Auth is by token, not cookies, so cross-origin clients are safe.
		InsecureSkipVerify: true,
	})
	if err != nil {
		return nil // Accept already wrote the response
	}
	conn.SetReadLimit(4096)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c := &wsConn{send: make(chan []byte, wsSendBuffer), done: make(chan struct{})}
	app.hub.add(u.ID, c)
	defer app.hub.remove(u.ID, c)

	// Writer: events + keepalive pings.
	go func() {
		defer cancel()
		t := time.NewTicker(wsPingInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-c.done:
				conn.Close(websocket.StatusTryAgainLater, "too slow")
				return
			case b := <-c.send:
				wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageText, b)
				wcancel()
				if err != nil {
					return
				}
			case <-t.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Ping(pctx)
				pcancel()
				if err != nil {
					return
				}
			}
		}
	}()

	// Reader: client → server events.
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			conn.CloseNow()
			return nil
		}
		var msg struct {
			Type string `json:"type"`
			Data struct {
				ChatID int64 `json:"chat_id"`
			} `json:"data"`
		}
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		switch msg.Type {
		case "typing":
			if app.isMember(ctx, msg.Data.ChatID, u.ID) == nil {
				app.broadcastChat(ctx, msg.Data.ChatID, "typing", map[string]int64{"chat_id": msg.Data.ChatID, "user_id": u.ID}, u.ID)
			}
		}
	}
}

// Hijack lets websocket upgrades pass through the logging wrapper.
func (s *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := s.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("hijack not supported")
	}
	s.status = http.StatusSwitchingProtocols
	return hj.Hijack()
}

func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
