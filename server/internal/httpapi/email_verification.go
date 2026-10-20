package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/mail"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

const (
	// DefaultEmailCodeTTL is how long an emailed code works.
	DefaultEmailCodeTTL = 15 * time.Minute
	// DefaultEmailCodeAttempts is how many wrong codes end a code.
	DefaultEmailCodeAttempts = 5
	// emailSendTimeout bounds one SMTP delivery.
	emailSendTimeout = 15 * time.Second
)

// EmailVerificationStore keeps the outstanding codes; *store.Users
// implements it.
type EmailVerificationStore interface {
	SetEmailCode(ctx context.Context, userID, email, codeHash string, expiresAt time.Time) (store.User, error)
	ConfirmEmail(ctx context.Context, userID string, now time.Time, maxAttempts int, matches func(email, codeHash string) bool) (store.User, store.EmailCodeAttempt, error)
	ChangeUnverifiedEmail(ctx context.Context, userID, email string) (store.User, error)
}

// EmailVerification asks new accounts to prove they own their address
// before they can upload, share publicly or use the bots.
type EmailVerification struct {
	Store  EmailVerificationStore
	Mailer mail.Sender
	Codes  *auth.EmailCodes
	// SendUserRate and SendIPRate bound the codes mailed.
	SendUserRate *RateLimiter
	SendIPRate   *RateLimiter
	// ConfirmUserRate and ConfirmIPRate bound code checks, on top of the
	// attempts each code allows.
	ConfirmUserRate *RateLimiter
	ConfirmIPRate   *RateLimiter
	TTL             time.Duration
	MaxAttempts     int
}

// WithEmailVerification turns email verification on. Without it, every
// account counts as verified.
func (h *AuthHandlers) WithEmailVerification(verification EmailVerification) *AuthHandlers {
	if verification.TTL <= 0 {
		verification.TTL = DefaultEmailCodeTTL
	}
	if verification.MaxAttempts <= 0 {
		verification.MaxAttempts = DefaultEmailCodeAttempts
	}
	h.verification = &verification
	return h
}

func (h *AuthHandlers) registerEmailVerification(mux *http.ServeMux) {
	if h.verification == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/me/email/code", h.handleSendEmailCode)
	mux.HandleFunc("POST /api/v1/me/email/verify", h.handleVerifyEmail)
	mux.HandleFunc("PUT /api/v1/me/email", h.handleChangeEmail)
}

// emailVerified says whether the account may use what verification gates.
func (h *AuthHandlers) emailVerified(user store.User) bool {
	return h.verification == nil || user.EmailVerifiedAt != nil
}

// EmailGate is what keeps unverified accounts from gated endpoints; nil
// when verification is off.
func (h *AuthHandlers) EmailGate() *EmailGate {
	if h.verification == nil {
		return nil
	}
	return &EmailGate{users: h.users}
}

// EmailGate refuses accounts that have not verified their email yet. A nil
// gate lets everyone through.
type EmailGate struct {
	users interface {
		ByID(ctx context.Context, id string) (store.User, error)
	}
}

// allow writes 403 email_unverified, or another error, and returns false
// when userID may not go on.
func (g *EmailGate) allow(w http.ResponseWriter, r *http.Request, userID string) bool {
	if g == nil {
		return true
	}
	user, err := g.users.ByID(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return false
	}
	if err != nil {
		internalError(w, "check email verification", err)
		return false
	}
	if user.EmailVerifiedAt == nil {
		writeError(w, http.StatusForbidden, "email_unverified")
		return false
	}
	return true
}

// PublishGate decides who publishes directly (#322): verified accounts and
// admins list a playlist publicly or publish a track at once; anyone else
// only asks, and an admin approves or rejects the request.
func (h *AuthHandlers) PublishGate() *PublishGate {
	return &PublishGate{auth: h}
}

// PublishGate is checked against a fresh account lookup, so a verification
// an admin just granted or revoked counts at once. A nil gate lets everyone
// publish directly.
type PublishGate struct {
	auth *AuthHandlers
}

// direct reports whether userID publishes without review. When ok is false
// it has written the error itself.
func (g *PublishGate) direct(w http.ResponseWriter, r *http.Request, userID string) (direct, ok bool) {
	if g == nil {
		return true, true
	}
	user, err := g.auth.users.ByID(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return false, false
	}
	if err != nil {
		internalError(w, "check publish permission", err)
		return false, false
	}
	return user.Verified || g.auth.isAdmin(user), true
}

var errEmailNotSent = errors.New("verification email not sent")

// sendEmailCode replaces the account's code with a new one and mails it.
// The code itself is never logged.
func (h *AuthHandlers) sendEmailCode(ctx context.Context, user store.User) (time.Time, error) {
	v := h.verification
	code, err := v.Codes.New()
	if err != nil {
		return time.Time{}, err
	}
	expiresAt := time.Now().Add(v.TTL)
	if _, err := v.Store.SetEmailCode(ctx, user.ID, user.Email, v.Codes.Hash(user.ID, user.Email, code), expiresAt); err != nil {
		return time.Time{}, err
	}
	// The code is stored; a client hanging up must not stop the email.
	sendCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), emailSendTimeout)
	defer cancel()
	if err := v.Mailer.Send(sendCtx, mail.VerificationCode(user.Email, code, int(v.TTL/time.Minute))); err != nil {
		slog.Warn("verification email not sent", "account", user.ID, "error", err)
		return time.Time{}, errEmailNotSent
	}
	return expiresAt, nil
}

// afterRegister mails the first code. A failure only means the user has to
// ask for another one, so registration still succeeds.
func (h *AuthHandlers) afterRegister(ctx context.Context, user store.User) {
	if h.verification == nil {
		return
	}
	if _, err := h.sendEmailCode(ctx, user); err != nil && !errors.Is(err, errEmailNotSent) {
		slog.Warn("verification code not created", "account", user.ID, "error", err)
	}
}

type emailCodeResponse struct {
	ExpiresAt time.Time `json:"expiresAt"`
}

func (h *AuthHandlers) handleSendEmailCode(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.verification.SendUserRate, userID) ||
		!enforceRateLimit(w, h.verification.SendIPRate, clientIP(r)) {
		return
	}
	user, ok := h.currentUser(w, r, userID)
	if !ok {
		return
	}
	expiresAt, err := h.sendEmailCode(r.Context(), user)
	h.writeSendResult(w, err, func() {
		writeJSON(w, http.StatusAccepted, emailCodeResponse{ExpiresAt: expiresAt.UTC()})
	})
}

func (h *AuthHandlers) writeSendResult(w http.ResponseWriter, err error, ok func()) {
	switch {
	case errors.Is(err, store.ErrEmailAlreadyVerified):
		writeError(w, http.StatusConflict, "email_already_verified")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	case errors.Is(err, store.ErrNoEmailCode):
		// The address changed meanwhile; asking again sends to the new one.
		writeError(w, http.StatusConflict, "email_changed")
	case errors.Is(err, errEmailNotSent):
		writeError(w, http.StatusBadGateway, "email_send_failed")
	case err != nil:
		internalError(w, "send verification code", err)
	default:
		ok()
	}
}

func (h *AuthHandlers) handleVerifyEmail(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.verification.ConfirmUserRate, userID) ||
		!enforceRateLimit(w, h.verification.ConfirmIPRate, clientIP(r)) {
		return
	}
	var input struct {
		Code string `json:"code"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	code, valid := normalizeEmailCode(input.Code)
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid_code")
		return
	}
	codes := h.verification.Codes
	user, attempt, err := h.verification.Store.ConfirmEmail(r.Context(), userID, time.Now(),
		h.verification.MaxAttempts, func(email, hash string) bool {
			return codes.Matches(userID, email, code, hash)
		})
	switch {
	case errors.Is(err, store.ErrEmailCodeMismatch):
		writeJSON(w, http.StatusBadRequest, struct {
			Error        string `json:"error"`
			AttemptsLeft int    `json:"attemptsLeft"`
		}{"wrong_code", attempt.AttemptsLeft})
	case errors.Is(err, store.ErrEmailCodeLocked):
		writeError(w, http.StatusConflict, "code_locked")
	case errors.Is(err, store.ErrEmailCodeExpired):
		writeError(w, http.StatusGone, "code_expired")
	case errors.Is(err, store.ErrNoEmailCode):
		writeError(w, http.StatusConflict, "no_code")
	case errors.Is(err, store.ErrEmailAlreadyVerified):
		writeError(w, http.StatusConflict, "email_already_verified")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusUnauthorized, "unauthorized")
	case err != nil:
		internalError(w, "verify email", err)
	default:
		slog.Info("email verified", "account", user.ID)
		writeJSON(w, http.StatusOK, h.userResponse(user))
	}
}

type changeEmailResponse struct {
	User userResponse `json:"user"`
	// CodeSent is false when the new address could not be mailed yet.
	CodeSent bool `json:"codeSent"`
}

// handleChangeEmail corrects the address of an account that has not
// verified it yet, then mails a code to the new address.
func (h *AuthHandlers) handleChangeEmail(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	userID, ok := authenticate(h.tokens, w, r)
	if !ok {
		return
	}
	if !enforceRateLimit(w, h.verification.SendUserRate, userID) ||
		!enforceRateLimit(w, h.verification.SendIPRate, clientIP(r)) {
		return
	}
	var input struct {
		Email string `json:"email"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	email, valid := normalizeEmail(input.Email)
	if !valid {
		writeError(w, http.StatusBadRequest, "invalid_email")
		return
	}
	user, err := h.verification.Store.ChangeUnverifiedEmail(r.Context(), userID, email)
	switch {
	case errors.Is(err, store.ErrEmailTaken):
		writeError(w, http.StatusConflict, "email_taken")
		return
	case errors.Is(err, store.ErrEmailAlreadyVerified):
		writeError(w, http.StatusConflict, "email_already_verified")
		return
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	case err != nil:
		internalError(w, "change email", err)
		return
	}
	_, err = h.sendEmailCode(r.Context(), user)
	if err != nil && !errors.Is(err, errEmailNotSent) {
		slog.Warn("verification code not created", "account", user.ID, "error", err)
	}
	writeJSON(w, http.StatusOK, changeEmailResponse{User: h.userResponse(user), CodeSent: err == nil})
}

func (h *AuthHandlers) currentUser(w http.ResponseWriter, r *http.Request, userID string) (store.User, bool) {
	user, err := h.users.ByID(r.Context(), userID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return store.User{}, false
	}
	if err != nil {
		internalError(w, "find user", err)
		return store.User{}, false
	}
	return user, true
}

// decodeStrict reads one small JSON object with no unknown fields.
func decodeStrict(w http.ResponseWriter, r *http.Request, into any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAuthBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil || decoder.Decode(new(any)) != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return false
	}
	return true
}

// normalizeEmailCode accepts the code as typed on a Persian or Arabic
// keyboard, with spaces, and returns it in ASCII digits.
func normalizeEmailCode(raw string) (string, bool) {
	var code strings.Builder
	for _, r := range raw {
		switch {
		case r >= '0' && r <= '9':
			code.WriteRune(r)
		case r >= '۰' && r <= '۹':
			code.WriteRune('0' + r - '۰')
		case r >= '٠' && r <= '٩':
			code.WriteRune('0' + r - '٠')
		case r == ' ' || r == '-' || r == '‌':
		default:
			return "", false
		}
	}
	return code.String(), code.Len() == auth.EmailCodeDigits
}
