package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const maxAuthBodyBytes = 4 << 10

// UserStore is the persistence the auth endpoints need; *store.Users implements it.
type UserStore interface {
	Create(ctx context.Context, email, passwordHash string) (store.User, error)
	ByEmail(ctx context.Context, email string) (store.User, string, error)
	ByID(ctx context.Context, id string) (store.User, error)
}

// SessionRevoker ends every session of an account; *store.Users implements it.
type SessionRevoker interface {
	RevokeSessions(ctx context.Context, id string) (store.User, error)
}

type AuthRateLimiters struct {
	Register *RateLimiter
	Login    *RateLimiter
	// LoginAccount limits sign-in attempts per email, whichever IPs they come
	// from, so guesses spread over many addresses still slow down (#215). It
	// applies to unknown emails too, so it reveals nothing about accounts.
	LoginAccount *RateLimiter
}

// AccountDeleter removes an account and everything it owns from the
// database; *store.Users implements it.
type AccountDeleter interface {
	Delete(ctx context.Context, userID string, grace time.Duration) (store.AccountDeletion, error)
}

// PrefixRemover deletes every stored object under a prefix;
// *storage.Storage implements it.
type PrefixRemover interface {
	RemovePrefix(ctx context.Context, prefix string) (int, error)
}

// AccountDeletion configures DELETE /api/v1/me.
type AccountDeletion struct {
	Accounts AccountDeleter
	Objects  PrefixRemover
	// Rate is applied per account and per IP, since each attempt checks a
	// password.
	Rate *RateLimiter
	// Grace is how long uploads handed out before the deletion may still
	// land in storage; the purge job keeps sweeping until then.
	Grace time.Duration
}

// accountObjectsTimeout bounds removing a deleted account's objects during
// the request; whatever is left is removed by the purge job.
const accountObjectsTimeout = 20 * time.Second

type AuthHandlers struct {
	users     UserStore
	passwords auth.Passwords
	tokens    *auth.Tokens
	limiters  AuthRateLimiters
	deletion  AccountDeletion
	// dummyHash is compared against when an email is unknown, so a login for a
	// missing account takes as long as one with a wrong password.
	dummyHash string
	admins    map[string]bool
	revoker   SessionRevoker
	sessions  *auth.Sessions
	// verification is nil when email verification is off.
	verification *EmailVerification
}

func NewAuthHandlers(users UserStore, passwords auth.Passwords, tokens *auth.Tokens, limiters AuthRateLimiters) (*AuthHandlers, error) {
	dummyHash, err := passwords.Hash("rhythmo-timing-equaliser")
	if err != nil {
		return nil, err
	}
	return &AuthHandlers{users: users, passwords: passwords, tokens: tokens, limiters: limiters, dummyHash: dummyHash}, nil
}

func (h *AuthHandlers) register(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/register", h.handleRegister)
	mux.HandleFunc("POST /api/v1/auth/login", h.handleLogin)
	mux.HandleFunc("GET /api/v1/me", h.handleMe)
	if h.deletion.Accounts != nil && h.deletion.Objects != nil {
		mux.HandleFunc("DELETE /api/v1/me", h.handleDeleteAccount)
	}
	h.registerEmailVerification(mux)
	h.registerAccountCodes(mux)
	if h.revoker != nil {
		mux.HandleFunc("POST /api/v1/auth/sessions/revoke", h.handleRevokeSessions)
	}
}

// WithSessionRevocation serves POST /api/v1/auth/sessions/revoke, which signs
// the account out everywhere. sessions is the cache the tokens check, so
// this process sees a revocation or deletion at once.
func (h *AuthHandlers) WithSessionRevocation(revoker SessionRevoker, sessions *auth.Sessions) *AuthHandlers {
	h.revoker, h.sessions = revoker, sessions
	return h
}

// handleRevokeSessions ends every session of the caller's account, on every
// device, and answers with a fresh session so the device that asked stays
// signed in.
func (h *AuthHandlers) handleRevokeSessions(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	user, err := h.revoker.RevokeSessions(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "revoke sessions", err)
		return
	}
	if h.sessions != nil {
		h.sessions.Forget(user.ID)
	}
	slog.Info("sessions revoked", "account", user.ID)
	w.Header().Set("Cache-Control", "no-store")
	h.writeSession(w, http.StatusOK, user)
}

// WithAccountDeletion lets signed-in users delete their own account.
func (h *AuthHandlers) WithAccountDeletion(deletion AccountDeletion) *AuthHandlers {
	h.deletion = deletion
	return h
}

type credentials struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type userResponse struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	// Verified is the admin's manual badge; EmailVerified says whether the
	// account proved its address, and is always true while email
	// verification is off.
	Verified      bool `json:"verified"`
	EmailVerified bool `json:"emailVerified"`
	IsAdmin       bool `json:"isAdmin"`
}

type sessionResponse struct {
	Token     string       `json:"token"`
	ExpiresAt time.Time    `json:"expiresAt"`
	User      userResponse `json:"user"`
}

func (h *AuthHandlers) handleRegister(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, h.limiters.Register, clientIP(r)) {
		return
	}
	input, ok := decodeCredentials(w, r)
	if !ok {
		return
	}
	email, ok := normalizeEmail(input.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_email")
		return
	}
	if utf8.RuneCountInString(input.Password) < auth.MinPasswordLength || len(input.Password) > auth.MaxPasswordBytes {
		writeError(w, http.StatusBadRequest, "invalid_password")
		return
	}

	if auth.WeakPassword(input.Password, email) {
		writeError(w, http.StatusBadRequest, "weak_password")
		return
	}

	hash, err := h.passwords.Hash(input.Password)
	if err != nil {
		internalError(w, "hash password", err)
		return
	}
	if h.accountCodes() != nil {
		// The account is created once the emailed code comes back (#219).
		h.registerWithCode(w, r, email, hash)
		return
	}
	user, err := h.users.Create(r.Context(), email, hash)
	if errors.Is(err, store.ErrEmailTaken) {
		writeError(w, http.StatusConflict, "email_taken")
		return
	}
	if err != nil {
		internalError(w, "create user", err)
		return
	}
	h.afterRegister(r.Context(), user)
	h.writeSession(w, http.StatusCreated, user)
}

func (h *AuthHandlers) handleLogin(w http.ResponseWriter, r *http.Request) {
	if !enforceRateLimit(w, h.limiters.Login, clientIP(r)) {
		return
	}
	input, ok := decodeCredentials(w, r)
	if !ok {
		return
	}
	email, validEmail := normalizeEmail(input.Email)
	if !validEmail || len(input.Password) > auth.MaxPasswordBytes {
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	if !enforceRateLimit(w, h.limiters.LoginAccount, email) {
		return
	}

	user, hash, err := h.users.ByEmail(r.Context(), email)
	if errors.Is(err, store.ErrNotFound) {
		_ = h.passwords.Verify(h.dummyHash, input.Password)
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	if err != nil {
		internalError(w, "find user", err)
		return
	}
	if err := h.passwords.Verify(hash, input.Password); err != nil {
		if !errors.Is(err, auth.ErrPasswordMismatch) {
			internalError(w, "verify password", err)
			return
		}
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}
	h.writeSession(w, http.StatusOK, user)
}

func (h *AuthHandlers) handleMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	user, err := h.users.ByID(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "find user", err)
		return
	}
	writeJSON(w, http.StatusOK, h.userResponse(user))
}

// handleDeleteAccount deletes the caller's account after checking their
// password again. The database rows go first, in one statement that also
// queues the account's storage prefix, so a crash can never leave an account
// that signs in to find its audio gone; the objects are removed next, and
// anything left behind is removed by the purge job.
func (h *AuthHandlers) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.deletion.Rate, "user:"+userID) ||
		!enforceRateLimit(w, h.deletion.Rate, "ip:"+clientIP(r)) {
		return
	}
	var input struct {
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}

	user, err := h.users.ByID(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "find user", err)
		return
	}
	_, hash, err := h.users.ByEmail(r.Context(), user.Email)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "find user", err)
		return
	}
	// 403, not 401: the session is still valid, only the password is wrong.
	if len(input.Password) > auth.MaxPasswordBytes {
		writeError(w, http.StatusForbidden, "invalid_password")
		return
	}
	if err := h.passwords.Verify(hash, input.Password); err != nil {
		if !errors.Is(err, auth.ErrPasswordMismatch) {
			internalError(w, "verify password", err)
			return
		}
		writeError(w, http.StatusForbidden, "invalid_password")
		return
	}

	deletion, err := h.deletion.Accounts.Delete(r.Context(), user.ID, h.deletion.Grace)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil {
		internalError(w, "delete account", err)
		return
	}
	slog.Info("account deleted", "account", deletion.UserID)
	// The account's tokens stop working with the next request (#216).
	if h.sessions != nil {
		h.sessions.Forget(deletion.UserID)
	}

	// The account is gone whatever happens next, so a client hanging up
	// must not stop the cleanup.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), accountObjectsTimeout)
	defer cancel()
	if removed, err := h.deletion.Objects.RemovePrefix(ctx, deletion.ObjectPrefix); err != nil {
		slog.Warn("deleted account objects left for the purge job", "account", deletion.UserID, "error", err)
	} else {
		slog.Info("deleted account objects removed", "account", deletion.UserID, "objects", removed)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *AuthHandlers) writeSession(w http.ResponseWriter, status int, user store.User) {
	token, expiresAt, err := h.tokens.IssueSession(user.ID, user.SessionEpoch)
	if err != nil {
		internalError(w, "issue token", err)
		return
	}
	writeJSON(w, status, sessionResponse{
		Token:     token,
		ExpiresAt: expiresAt.UTC(),
		User:      h.userResponse(user),
	})
}

// WithAdmins configures the operator-managed allowlist. No client can set roles.
func (h *AuthHandlers) WithAdmins(emails []string) *AuthHandlers {
	h.admins = make(map[string]bool)
	for _, email := range emails {
		if normalized, ok := normalizeEmail(email); ok {
			h.admins[normalized] = true
		}
	}
	return h
}

func (h *AuthHandlers) userResponse(user store.User) userResponse {
	return userResponse{
		ID: user.ID, Email: user.Email, Verified: user.Verified,
		EmailVerified: h.emailVerified(user), IsAdmin: h.isAdmin(user),
	}
}

// isAdmin needs the address to be verified too, so someone who registers an
// allowlisted address that no account holds any more can't become an admin.
func (h *AuthHandlers) isAdmin(user store.User) bool {
	return h.admins[user.Email] && h.emailVerified(user)
}

func decodeCredentials(w http.ResponseWriter, r *http.Request) (credentials, bool) {
	var input credentials
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return credentials{}, false
	}
	return input, true
}

// normalizeEmail trims and lower-cases an address and rejects anything that is
// not a bare address, such as "Name <a@b.c>".
func normalizeEmail(raw string) (string, bool) {
	email := strings.ToLower(strings.TrimSpace(raw))
	if email == "" || len(email) > 254 {
		return "", false
	}
	address, err := mail.ParseAddress(email)
	if err != nil || address.Address != email || !strings.Contains(email[strings.LastIndex(email, "@"):], ".") {
		return "", false
	}
	return email, true
}

// authenticate returns the user ID from a valid, unrevoked bearer token, or
// writes 401. When the revocation check itself fails it answers 503 instead:
// a 401 would make the app sign the user out over a database hiccup.
func authenticate(tokens *auth.Tokens, w http.ResponseWriter, r *http.Request) (string, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if ok && token != "" {
		userID, err := tokens.Authorize(r.Context(), token)
		if err == nil {
			return userID, true
		}
		if !errors.Is(err, auth.ErrInvalidToken) {
			slog.Error("request failed", "action", "check session", "error", err)
			writeError(w, http.StatusServiceUnavailable, "unavailable")
			return "", false
		}
	}
	writeError(w, http.StatusUnauthorized, "unauthorized")
	return "", false
}

// optionalUser is authenticate for endpoints visitors may also use without
// an account: no Authorization header means an anonymous caller (""), while
// a token that doesn't verify is still 401, so an expired session notices.
func optionalUser(tokens *auth.Tokens, w http.ResponseWriter, r *http.Request) (string, bool) {
	if r.Header.Get("Authorization") == "" {
		return "", true
	}
	return authenticate(tokens, w, r)
}

// internalError logs the cause without request data, so passwords never reach the logs.
func internalError(w http.ResponseWriter, action string, err error) {
	slog.Error("request failed", "action", action, "error", err)
	writeError(w, http.StatusInternalServerError, "internal_error")
}
