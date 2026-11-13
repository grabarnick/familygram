package main

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"
)

type User struct {
	ID           int64   `json:"id"`
	Phone        string  `json:"phone"`
	DisplayName  string  `json:"display_name"`
	AvatarFileID *string `json:"avatar_file_id"`
	IsAdmin      bool    `json:"is_admin"`
}

const userCols = `id, phone, display_name, avatar_file_id, is_admin`

func scanUser(sc interface{ Scan(...any) error }) (*User, error) {
	var u User
	var avatar sql.NullString
	if err := sc.Scan(&u.ID, &u.Phone, &u.DisplayName, &avatar, &u.IsAdmin); err != nil {
		return nil, err
	}
	if avatar.Valid {
		u.AvatarFileID = &avatar.String
	}
	return &u, nil
}

func (app *App) getUser(ctx context.Context, id int64) (*User, error) {
	u, err := scanUser(app.db.QueryRowContext(ctx, `SELECT `+userCols+` FROM users WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errStatus(http.StatusUnauthorized, "unauthorized")
	}
	return u, err
}

func (app *App) handleMe(w http.ResponseWriter, r *http.Request, u *User) error {
	writeJSON(w, http.StatusOK, u)
	return nil
}

func (app *App) handleUpdateMe(w http.ResponseWriter, r *http.Request, u *User) error {
	var req struct {
		DisplayName  *string `json:"display_name"`
		AvatarFileID *string `json:"avatar_file_id"`
	}
	if err := readJSON(r, &req); err != nil {
		return err
	}
	ctx := r.Context()
	if req.DisplayName != nil {
		name := strings.TrimSpace(*req.DisplayName)
		if name == "" || len([]rune(name)) > 64 {
			return errStatus(http.StatusBadRequest, "invalid display name")
		}
		if _, err := app.db.ExecContext(ctx, `UPDATE users SET display_name = ? WHERE id = ?`, name, u.ID); err != nil {
			return err
		}
	}
	if req.AvatarFileID != nil {
		var val any
		if *req.AvatarFileID != "" {
			var mime string
			err := app.db.QueryRowContext(ctx, `SELECT mime FROM files WHERE id = ? AND uploader_id = ?`, *req.AvatarFileID, u.ID).Scan(&mime)
			if err != nil || !strings.HasPrefix(mime, "image/") {
				return errStatus(http.StatusBadRequest, "invalid avatar file")
			}
			val = *req.AvatarFileID
		}
		if _, err := app.db.ExecContext(ctx, `UPDATE users SET avatar_file_id = ? WHERE id = ?`, val, u.ID); err != nil {
			return err
		}
	}
	nu, err := app.getUser(ctx, u.ID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, nu)
	return nil
}

func (app *App) handleUsers(w http.ResponseWriter, r *http.Request, u *User) error {
	rows, err := app.db.QueryContext(r.Context(), `SELECT `+userCols+` FROM users ORDER BY display_name`)
	if err != nil {
		return err
	}
	defer rows.Close()
	users := []*User{}
	for rows.Next() {
		uu, err := scanUser(rows)
		if err != nil {
			return err
		}
		users = append(users, uu)
	}
	writeJSON(w, http.StatusOK, users)
	return rows.Err()
}
