package main

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS users (
	id             INTEGER PRIMARY KEY,
	phone          TEXT NOT NULL UNIQUE,
	display_name   TEXT NOT NULL,
	avatar_file_id TEXT,
	is_admin       INTEGER NOT NULL DEFAULT 0,
	created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
	token_hash  TEXT PRIMARY KEY,
	user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	created_at  INTEGER NOT NULL,
	last_seen   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS allowed_phones (
	phone        TEXT PRIMARY KEY,
	display_name TEXT NOT NULL DEFAULT '',
	added_by     INTEGER,
	created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sms_codes (
	phone       TEXT PRIMARY KEY,
	code_hash   TEXT NOT NULL,
	expires_at  INTEGER NOT NULL,
	attempts    INTEGER NOT NULL DEFAULT 0,
	sent_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
	id           TEXT PRIMARY KEY,
	uploader_id  INTEGER NOT NULL REFERENCES users(id),
	name         TEXT NOT NULL,
	mime         TEXT NOT NULL,
	size         INTEGER NOT NULL,
	width        INTEGER NOT NULL DEFAULT 0,
	height       INTEGER NOT NULL DEFAULT 0,
	duration_ms  INTEGER NOT NULL DEFAULT 0,
	created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chats (
	id             INTEGER PRIMARY KEY,
	kind           TEXT NOT NULL CHECK (kind IN ('direct','group')),
	title          TEXT NOT NULL DEFAULT '',
	avatar_file_id TEXT,
	direct_key     TEXT UNIQUE,
	created_by     INTEGER,
	created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_members (
	chat_id       INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	last_read_id  INTEGER NOT NULL DEFAULT 0,
	joined_at     INTEGER NOT NULL,
	PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_chat_members_user ON chat_members(user_id);

CREATE TABLE IF NOT EXISTS messages (
	id           INTEGER PRIMARY KEY,
	chat_id      INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	sender_id    INTEGER NOT NULL REFERENCES users(id),
	client_id    TEXT NOT NULL,
	kind         TEXT NOT NULL,
	text         TEXT NOT NULL DEFAULT '',
	file_id      TEXT REFERENCES files(id),
	reply_to_id  INTEGER,
	created_at   INTEGER NOT NULL,
	deleted      INTEGER NOT NULL DEFAULT 0,
	UNIQUE (sender_id, client_id)
);
CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, id);
CREATE INDEX IF NOT EXISTS idx_messages_file ON messages(file_id);

CREATE TABLE IF NOT EXISTS calls (
	id            INTEGER PRIMARY KEY,
	chat_id       INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	initiator_id  INTEGER NOT NULL REFERENCES users(id),
	video         INTEGER NOT NULL DEFAULT 0,
	state         TEXT NOT NULL,
	created_at    INTEGER NOT NULL,
	answered_at   INTEGER,
	ended_at      INTEGER
);
CREATE INDEX IF NOT EXISTS idx_calls_chat ON calls(chat_id, state);

CREATE TABLE IF NOT EXISTS call_participants (
	call_id    INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
	user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	joined_at  INTEGER NOT NULL,
	left_at    INTEGER,
	PRIMARY KEY (call_id, user_id)
);

-- Phones that receive push notifications. Bound to the sign-in session, so
-- logging out (deleting the session) stops pushes to that phone.
CREATE TABLE IF NOT EXISTS push_devices (
	token        TEXT PRIMARY KEY,
	user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
	platform     TEXT NOT NULL,
	sandbox      INTEGER NOT NULL DEFAULT 0,
	updated_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS push_devices_user ON push_devices(user_id);
`

func openDB(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// Tens of users: one writer connection avoids SQLITE_BUSY entirely.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	if err := addColumn(db, "messages", "call_id", "INTEGER REFERENCES calls(id)"); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return db, nil
}

// addColumn adds a column if it does not exist yet (SQLite has no IF NOT EXISTS for columns).
func addColumn(db *sql.DB, table, column, decl string) error {
	rows, err := db.Query(`SELECT name FROM pragma_table_info(?)`, table)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	_, err = db.Exec(fmt.Sprintf(`ALTER TABLE %s ADD COLUMN %s %s`, table, column, decl))
	return err
}
