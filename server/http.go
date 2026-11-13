package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type apiError struct {
	Status int
	Msg    string
}

func (e *apiError) Error() string { return e.Msg }

func errStatus(status int, msg string) error { return &apiError{Status: status, Msg: msg} }

var (
	errNotFound  = errStatus(http.StatusNotFound, "not found")
	errForbidden = errStatus(http.StatusForbidden, "forbidden")
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, err error) {
	var ae *apiError
	if errors.As(err, &ae) {
		writeJSON(w, ae.Status, map[string]string{"error": ae.Msg})
		return
	}
	log.Printf("internal error: %v", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
}

func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	if err := dec.Decode(v); err != nil {
		return errStatus(http.StatusBadRequest, "invalid json")
	}
	return nil
}

func pathID(r *http.Request, name string) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue(name), 10, 64)
	if err != nil || id <= 0 {
		return 0, errStatus(http.StatusBadRequest, "invalid id")
	}
	return id, nil
}

type handlerFunc func(w http.ResponseWriter, r *http.Request) error
type authedFunc func(w http.ResponseWriter, r *http.Request, u *User) error

func (h handlerFunc) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := h(w, r); err != nil {
		writeErr(w, err)
	}
}

func (app *App) authed(h authedFunc) http.Handler {
	return handlerFunc(func(w http.ResponseWriter, r *http.Request) error {
		u, err := app.userFromRequest(r)
		if err != nil {
			return err
		}
		return h(w, r, u)
	})
}

func (app *App) routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /api/info", handlerFunc(app.handleInfo))
	mux.Handle("POST /api/auth/request-code", handlerFunc(app.handleRequestCode))
	mux.Handle("POST /api/auth/verify", handlerFunc(app.handleVerify))
	mux.Handle("POST /api/auth/logout", app.authed(app.handleLogout))
	mux.Handle("GET /api/me", app.authed(app.handleMe))
	mux.Handle("PATCH /api/me", app.authed(app.handleUpdateMe))
	mux.Handle("GET /api/users", app.authed(app.handleUsers))
	mux.Handle("GET /api/phones", app.authed(app.handleListPhones))
	mux.Handle("POST /api/phones", app.authed(app.handleAddPhone))
	mux.Handle("DELETE /api/phones/{phone}", app.authed(app.handleDeletePhone))
	mux.Handle("GET /api/chats", app.authed(app.handleListChats))
	mux.Handle("POST /api/chats", app.authed(app.handleCreateChat))
	mux.Handle("GET /api/chats/{id}/messages", app.authed(app.handleListMessages))
	mux.Handle("POST /api/chats/{id}/messages", app.authed(app.handleSendMessage))
	mux.Handle("POST /api/chats/{id}/read", app.authed(app.handleRead))
	mux.Handle("DELETE /api/messages/{id}", app.authed(app.handleDeleteMessage))
	mux.Handle("POST /api/files", app.authed(app.handleUpload))
	mux.Handle("GET /api/files/{id}", app.authed(app.handleDownload))
	mux.Handle("GET /api/ws", app.authed(app.handleWS))
	mux.Handle("POST /api/devices", app.authed(app.handleRegisterDevice))
	mux.Handle("POST /api/chats/{id}/call", app.authed(app.handleStartCall))
	mux.Handle("POST /api/calls/{id}/join", app.authed(app.handleJoinCall))
	mux.Handle("POST /api/calls/{id}/decline", app.authed(app.handleDeclineCall))
	mux.Handle("POST /api/calls/{id}/leave", app.authed(app.handleLeaveCall))
	mux.Handle("GET /api/calls", app.authed(app.handleListCalls))
	mux.Handle("POST /api/livekit/webhook", handlerFunc(app.handleLiveKitWebhook))
	mux.Handle("/api/", handlerFunc(func(w http.ResponseWriter, r *http.Request) error { return errNotFound }))
	mux.Handle("/", app.staticHandler())
	return withCORS(withLogging(mux))
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", "*")
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
			h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
			h.Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Content-Disposition")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController / websocket reach the underlying writer.
func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			// Never log query strings: they may carry tokens.
			log.Printf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
		}
	})
}

// staticHandler serves the Flutter web build with an index.html fallback (SPA).
func (app *App) staticHandler() http.Handler {
	root := app.cfg.WebDir
	fs := http.FileServer(http.Dir(root))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		clean := filepath.Clean("/" + r.URL.Path)
		if st, err := os.Stat(filepath.Join(root, clean)); err == nil && !st.IsDir() {
			fs.ServeHTTP(w, r)
			return
		}
		index := filepath.Join(root, "index.html")
		if _, err := os.Stat(index); err != nil {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = w.Write([]byte(app.cfg.ServerName + " server is running. Web client is not installed.\n"))
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFile(w, r, index)
	})
}
