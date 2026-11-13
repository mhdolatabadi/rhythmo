package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// anonymousOwnerName stands in for an owner who has not picked a public
// name. No part of an owner's email is ever shown to other people (#378).
const anonymousOwnerName = "کاربر ریتمو"

// maxDisplayNameRunes matches the database check on users.display_name.
const maxDisplayNameRunes = 40

// publicOwnerName is how an owner is shown to everyone else: their display
// name, or a neutral placeholder.
func publicOwnerName(name string) string {
	if name = strings.TrimSpace(name); name != "" {
		return name
	}
	return anonymousOwnerName
}

// DisplayNameSetter changes an account's public name; *store.Users
// implements it.
type DisplayNameSetter interface {
	SetDisplayName(ctx context.Context, id, name string) (store.User, error)
}

// normalizeDisplayName trims and collapses whitespace and rejects names that
// are too long, hold control or bidi-override characters, or look like an
// email address (so nobody publishes theirs by accident). "" clears the name.
func normalizeDisplayName(raw string) (string, bool) {
	name := strings.Join(strings.Fields(raw), " ")
	if name == "" {
		return "", true
	}
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > maxDisplayNameRunes || strings.Contains(name, "@") {
		return "", false
	}
	for _, r := range name {
		// ZWNJ and ZWJ are part of ordinary Persian spelling.
		if r == '‌' || r == '‍' {
			continue
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return "", false
		}
	}
	return name, true
}

type profileInput struct {
	DisplayName *string `json:"displayName"`
}

// handleUpdateProfile is PATCH /api/v1/me: it sets the caller's public
// display name.
func (h *AuthHandlers) handleUpdateProfile(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	setter, ok := h.users.(DisplayNameSetter)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var input profileInput
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.DisplayName == nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	name, ok := normalizeDisplayName(*input.DisplayName)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_display_name")
		return
	}
	user, err := setter.SetDisplayName(r.Context(), userID, name)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "set display name", err)
		return
	}
	writeJSON(w, http.StatusOK, h.userResponse(user))
}
