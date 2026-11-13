// Familygram server: a small self-hosted family messenger backend.
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type Config struct {
	Addr           string
	DataDir        string
	WebDir         string
	ServerName     string
	AdminPhone     string // normalized E.164; may be empty
	MaxUploadBytes int64
	SMSProvider    string

	LiveKitURL    string // public wss:// URL handed to clients
	LiveKitKey    string
	LiveKitSecret string
}

type App struct {
	cfg Config
	db  *sql.DB
	hub *Hub
	sms SMSSender

	calls callRuntime
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() Config {
	maxMB, _ := strconv.ParseInt(env("FG_MAX_UPLOAD_MB", "200"), 10, 64)
	admin := ""
	if raw := os.Getenv("FG_ADMIN_PHONE"); raw != "" {
		p, err := normalizePhone(raw)
		if err != nil {
			log.Fatalf("FG_ADMIN_PHONE: %v", err)
		}
		admin = p
	}
	return Config{
		Addr:           env("FG_ADDR", ":8080"),
		DataDir:        env("FG_DATA_DIR", "./data"),
		WebDir:         env("FG_WEB_DIR", "./web"),
		ServerName:     env("FG_SERVER_NAME", "Familygram"),
		AdminPhone:     admin,
		MaxUploadBytes: maxMB << 20,
		SMSProvider:    env("FG_SMS_PROVIDER", "log"),
		LiveKitURL:     os.Getenv("FG_LIVEKIT_URL"),
		LiveKitKey:     os.Getenv("FG_LIVEKIT_API_KEY"),
		LiveKitSecret:  os.Getenv("FG_LIVEKIT_API_SECRET"),
	}
}

func main() {
	cfg := loadConfig()
	if err := os.MkdirAll(filepath.Join(cfg.DataDir, "files"), 0o755); err != nil {
		log.Fatal(err)
	}
	db, err := openDB(filepath.Join(cfg.DataDir, "familygram.db"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	sender, err := newSMSSender(cfg.SMSProvider)
	if err != nil {
		log.Fatal(err)
	}
	app := &App{cfg: cfg, db: db, hub: newHub(), sms: sender}

	// CLI subcommands for self-hosters.
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "add-phone":
			if len(os.Args) < 3 || len(os.Args) > 4 {
				log.Fatal(`usage: familygram add-phone <phone> ["Display Name"]`)
			}
			name := ""
			if len(os.Args) == 4 {
				name = os.Args[3]
			}
			phone, err := app.addAllowedPhone(context.Background(), os.Args[2], name, 0)
			if err != nil {
				log.Fatal(err)
			}
			fmt.Println("added", phone)
			return
		default:
			log.Fatalf("unknown command %q (available: add-phone)", os.Args[1])
		}
	}

	if err := app.recoverCalls(context.Background()); err != nil {
		log.Fatal(err)
	}
	if !app.callsEnabled() {
		log.Printf("calls disabled: set FG_LIVEKIT_URL, FG_LIVEKIT_API_KEY, FG_LIVEKIT_API_SECRET")
	}

	if cfg.AdminPhone == "" {
		log.Printf("warning: FG_ADMIN_PHONE is not set; add phones with `familygram add-phone`")
	}

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           app.routes(),
		ReadHeaderTimeout: 15 * time.Second,
	}

	go func() {
		log.Printf("familygram listening on %s (data: %s, sms: %s)", cfg.Addr, cfg.DataDir, cfg.SMSProvider)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
