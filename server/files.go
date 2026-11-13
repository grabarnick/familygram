package main

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func (app *App) filePath(id string) string { return filepath.Join(app.cfg.DataDir, "files", id) }

func isHexID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func cleanFileName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	name = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, name)
	if name == "." || name == "/" || name == "" {
		name = "file"
	}
	for utf8.RuneCountInString(name) > 200 {
		_, size := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-size]
	}
	return name
}

func (app *App) handleUpload(w http.ResponseWriter, r *http.Request, u *User) error {
	r.Body = http.MaxBytesReader(w, r.Body, app.cfg.MaxUploadBytes+(1<<20))
	mr, err := r.MultipartReader()
	if err != nil {
		return errStatus(http.StatusBadRequest, "multipart/form-data expected")
	}
	id := randomHex(16)
	dst := app.filePath(id)
	var f File
	f.ID = id
	gotFile := false
	cleanup := func() { _ = os.Remove(dst) }

	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			if gotFile {
				cleanup()
			}
			return errStatus(http.StatusBadRequest, "bad multipart body")
		}
		switch part.FormName() {
		case "file":
			if gotFile {
				part.Close()
				continue
			}
			f.Name = cleanFileName(part.FileName())
			f.Mime = strings.TrimSpace(part.Header.Get("Content-Type"))
			out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
			if err != nil {
				return err
			}
			head := make([]byte, 512)
			n, _ := io.ReadFull(part, head)
			head = head[:n]
			if _, err := out.Write(head); err != nil {
				out.Close()
				cleanup()
				return err
			}
			rest, err := io.Copy(out, io.LimitReader(part, app.cfg.MaxUploadBytes-int64(n)+1))
			cerr := out.Close()
			gotFile = true
			if err != nil {
				cleanup()
				var mbe *http.MaxBytesError
				if errors.As(err, &mbe) {
					return errStatus(http.StatusRequestEntityTooLarge, "file too large")
				}
				return errStatus(http.StatusBadRequest, "upload interrupted")
			}
			if cerr != nil {
				cleanup()
				return cerr
			}
			f.Size = int64(n) + rest
			if f.Size > app.cfg.MaxUploadBytes {
				cleanup()
				return errStatus(http.StatusRequestEntityTooLarge, "file too large")
			}
			if f.Mime == "" || f.Mime == "application/octet-stream" {
				if byExt := mime.TypeByExtension(strings.ToLower(filepath.Ext(f.Name))); byExt != "" {
					f.Mime = byExt
				} else {
					f.Mime = http.DetectContentType(head)
				}
			}
			if mt, params, err := mime.ParseMediaType(f.Mime); err == nil {
				f.Mime = mime.FormatMediaType(mt, params)
			} else {
				f.Mime = "application/octet-stream"
			}
		case "width", "height", "duration_ms":
			b, _ := io.ReadAll(io.LimitReader(part, 32))
			v, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
			if v < 0 {
				v = 0
			}
			switch part.FormName() {
			case "width":
				f.Width = int(min(v, 100000))
			case "height":
				f.Height = int(min(v, 100000))
			default:
				f.DurationMs = v
			}
		}
		part.Close()
	}
	if !gotFile {
		return errStatus(http.StatusBadRequest, `multipart field "file" required`)
	}
	_, err = app.db.ExecContext(r.Context(), `INSERT INTO files (id, uploader_id, name, mime, size, width, height, duration_ms, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, f.ID, u.ID, f.Name, f.Mime, f.Size, f.Width, f.Height, f.DurationMs, nowMs())
	if err != nil {
		cleanup()
		return err
	}
	writeJSON(w, http.StatusOK, f)
	return nil
}

// fileAccessible: uploader, attached to a live message in a chat the user is
// in, or used as a user/chat avatar.
func (app *App) fileAccessible(ctx context.Context, fileID string, uid int64) bool {
	var one int
	err := app.db.QueryRowContext(ctx, `
		SELECT 1 FROM files f WHERE f.id = ? AND (
		  f.uploader_id = ?
		  OR EXISTS (SELECT 1 FROM messages m JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?
		             WHERE m.file_id = f.id AND m.deleted = 0)
		  OR EXISTS (SELECT 1 FROM users u WHERE u.avatar_file_id = f.id)
		  OR EXISTS (SELECT 1 FROM chats c JOIN chat_members cm ON cm.chat_id = c.id AND cm.user_id = ?
		             WHERE c.avatar_file_id = f.id))`, fileID, uid, uid, uid).Scan(&one)
	return err == nil
}

func inlineMime(m string) bool {
	if strings.HasPrefix(m, "image/svg") {
		return false // SVG can carry scripts
	}
	return strings.HasPrefix(m, "image/") || strings.HasPrefix(m, "video/") || strings.HasPrefix(m, "audio/")
}

func (app *App) handleDownload(w http.ResponseWriter, r *http.Request, u *User) error {
	id := r.PathValue("id")
	if !isHexID(id) || !app.fileAccessible(r.Context(), id, u.ID) {
		return errNotFound
	}
	var name, mt string
	var created int64
	err := app.db.QueryRowContext(r.Context(), `SELECT name, mime, created_at FROM files WHERE id = ?`, id).Scan(&name, &mt, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return errNotFound
	}
	if err != nil {
		return err
	}
	fh, err := os.Open(app.filePath(id))
	if err != nil {
		return errNotFound
	}
	defer fh.Close()

	disp := "attachment"
	if inlineMime(mt) {
		disp = "inline"
	}
	ascii := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e || r == '"' || r == '\\' {
			return '_'
		}
		return r
	}, name)
	h := w.Header()
	h.Set("Content-Type", mt)
	h.Set("Content-Disposition", disp+`; filename="`+ascii+`"; filename*=UTF-8''`+url.PathEscape(name))
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "sandbox")
	h.Set("Cache-Control", "private, max-age=31536000, immutable")
	http.ServeContent(w, r, "", time.UnixMilli(created), fh)
	return nil
}
