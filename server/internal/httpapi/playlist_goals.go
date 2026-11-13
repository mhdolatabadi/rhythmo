package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// PlaylistGoalStore keeps shared goals and each listener's occasion
// collections (#276); *store.Playlists implements it.
type PlaylistGoalStore interface {
	SetGoal(ctx context.Context, actorID, playlistID string, goal *int) (store.Playlist, error)
	SetOccasion(ctx context.Context, userID, playlistID, occasion string) error
}

// maxOccasionRunes caps an occasion collection's name.
const maxOccasionRunes = 40

func (h *PlaylistHandlers) registerGoals(mux *http.ServeMux) {
	goals, ok := h.playlists.(PlaylistGoalStore)
	if !ok {
		return
	}
	mux.HandleFunc("PUT /api/v1/playlists/{id}/goal", func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok {
			return
		}
		var input struct {
			Goal *int `json:"goal"`
		}
		if !decodeSmall(w, r, &input) || (input.Goal != nil && (*input.Goal < 1 || *input.Goal > store.MaxGoalTracks)) {
			writeError(w, http.StatusBadRequest, "invalid_goal")
			return
		}
		playlist, err := goals.SetGoal(r.Context(), userID, r.PathValue("id"), input.Goal)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found")
			return
		}
		if err != nil {
			internalError(w, "set playlist goal", err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"goal": playlist.GoalTracks})
	})
	mux.HandleFunc("PUT /api/v1/playlists/{id}/occasion", func(w http.ResponseWriter, r *http.Request) {
		userID, ok := authenticate(h.tokens, w, r)
		if !ok {
			return
		}
		var input struct {
			Occasion string `json:"occasion"`
		}
		if !decodeSmall(w, r, &input) {
			writeError(w, http.StatusBadRequest, "invalid_occasion")
			return
		}
		occasion := strings.Join(strings.Fields(input.Occasion), " ")
		if utf8.RuneCountInString(occasion) > maxOccasionRunes || !utf8.ValidString(occasion) {
			writeError(w, http.StatusBadRequest, "invalid_occasion")
			return
		}
		err := goals.SetOccasion(r.Context(), userID, r.PathValue("id"), occasion)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found")
			return
		}
		if err != nil {
			internalError(w, "set playlist occasion", err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"occasion": occasion})
	})
}

// decodeSmall reads one small JSON object with only known fields.
func decodeSmall(w http.ResponseWriter, r *http.Request, into any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	d.DisallowUnknownFields()
	return d.Decode(into) == nil && d.Decode(&struct{}{}) == io.EOF
}
