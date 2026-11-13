package httpapi

import (
	"encoding/json"
	"net/http"
)

type healthResponse struct {
	Status string `json:"status"`
}

type Config struct {
	// AllowedOrigin is the web origin allowed to call the API cross-origin.
	AllowedOrigin string
	Auth          *AuthHandlers
	Admin         *AdminHandlers
	Tracks        *TrackHandlers
	Playlists     *PlaylistHandlers
	// History is each user's recently played tracks.
	History *HistoryHandlers
	// ForYou is «برای تو»: smart playlists, daily mixes and radio (#226).
	ForYou *ForYouHandlers
	Bots   *BotHandlers
	// LinkImports adds music from song pages and audio links.
	LinkImports *LinkImportHandlers
	// Lyrics serves song lyrics looked up from LRCLIB.
	Lyrics *LyricsHandlers
	// Identify recognises songs from a recorded snippet.
	Identify *IdentifyHandlers
	// Store is the public store: every song in a public playlist, listed
	// once.
	Store *CatalogHandlers
	// Likes publishes single tracks and keeps likes (#284).
	Likes *LikeHandlers
	// Public serves the public HTML pages at /, /p/{token}, sitemap.xml and
	// robots.txt.
	Public *PublicPages
	// Ops is served only when an operator token is configured.
	Ops *OpsHandlers
	// Webhooks maps a messenger provider name to its bot webhook, served at
	// /api/v1/bots/{provider}/webhook/{secret}.
	Webhooks map[string]http.Handler
}

func NewHandler(config Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", health)
	if config.Auth != nil {
		config.Auth.register(mux)
	}
	if config.Admin != nil {
		config.Admin.register(mux)
	}
	if config.Tracks != nil {
		config.Tracks.register(mux)
	}
	if config.Playlists != nil {
		config.Playlists.register(mux)
	}
	if config.History != nil {
		config.History.register(mux)
	}
	if config.Bots != nil {
		config.Bots.register(mux)
	}
	if config.LinkImports != nil {
		config.LinkImports.register(mux)
	}
	if config.Lyrics != nil {
		config.Lyrics.register(mux)
	}
	if config.Identify != nil {
		config.Identify.register(mux)
	}
	if config.Store != nil {
		config.Store.register(mux)
	}
	if config.ForYou != nil {
		config.ForYou.register(mux)
	}
	if config.Likes != nil {
		config.Likes.register(mux)
	}
	if config.Public != nil {
		config.Public.register(mux)
	}
	if config.Ops != nil {
		config.Ops.register(mux)
	}
	for provider, handler := range config.Webhooks {
		mux.Handle("POST /api/v1/bots/"+provider+"/webhook/{secret}", handler)
	}
	return securityHeaders(cors(config.AllowedOrigin, mux))
}

func cors(allowedOrigin string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Add("Vary", "Origin")
		if allowedOrigin == "" || r.Header.Get("Origin") != allowedOrigin {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", allowedOrigin)
		if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, If-Match")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type errorResponse struct {
	Error string `json:"error"`
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, errorResponse{Error: code})
}
