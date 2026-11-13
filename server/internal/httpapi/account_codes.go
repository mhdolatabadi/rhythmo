package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"
	"unicode/utf8"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/mail"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// Sign-up by emailed code (#219) and password reset (#380). Both answer the
// same way whether or not an account has the address, so neither tells
// anyone which emails are registered. They need email verification to be
// on, since that is what sends mail.

// AccountCodeStore keeps sign-ups waiting for their code and password reset
// codes; *store.Users implements it.
type AccountCodeStore interface {
	SetPendingRegistration(ctx context.Context, email, passwordHash, codeHash string, expiresAt time.Time) error
	ConfirmRegistration(ctx context.Context, email string, now time.Time, maxAttempts int, matches func(codeHash string) bool) (store.User, error)
	SetPasswordResetCode(ctx context.Context, email string, hash func(userID string) string, expiresAt time.Time) (store.User, error)
	ResetPassword(ctx context.Context, email string, now time.Time, maxAttempts int, matches func(userID, email, codeHash string) bool, passwordHash string) (store.User, error)
}

// codeSentResponse is the one answer to a sign-up or reset request.
type codeSentResponse struct {
	Status string `json:"status"`
}

// Purposes keep the code hashes of sign-up, reset and verification apart.
const (
	signupCodeSubject = "signup"
	resetCodeSubject  = "reset:"
)

func (h *AuthHandlers) accountCodes() AccountCodeStore {
	if h.verification == nil {
		return nil
	}
	codes, _ := h.verification.Store.(AccountCodeStore)
	return codes
}

func (h *AuthHandlers) registerAccountCodes(mux *http.ServeMux) {
	if h.accountCodes() == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/register/confirm", h.handleConfirmRegistration)
	mux.HandleFunc("POST /api/v1/auth/password/forgot", h.handleForgotPassword)
	mux.HandleFunc("POST /api/v1/auth/password/reset", h.handleResetPassword)
}

// deliver sends message without making the request wait for SMTP, so a
// known and an unknown address take the same time to answer. Nothing about
// the message is logged but the failure.
func (h *AuthHandlers) deliver(ctx context.Context, message mail.Message) {
	send := func() {
		sendCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), emailSendTimeout)
		defer cancel()
		if err := h.verification.Mailer.Send(sendCtx, message); err != nil {
			slog.Warn("account email not sent", "error", err)
		}
	}
	if h.verification.syncMail {
		send()
		return
	}
	go send()
}

// registerWithCode keeps the sign-up until its code is confirmed and mails
// the code, or, when the address already has an account, mails its owner a
// notice instead. The answer is the same either way.
func (h *AuthHandlers) registerWithCode(w http.ResponseWriter, r *http.Request, email, passwordHash string) {
	v, codes := h.verification, h.accountCodes()
	_, _, err := h.users.ByEmail(r.Context(), email)
	switch {
	case err == nil:
		// One notice per address per window; more would only be spam.
		if allowed, _ := v.SendUserRate.Allow("signup:" + email); allowed {
			h.deliver(r.Context(), mail.SignupAttempt(email))
		}
	case errors.Is(err, store.ErrNotFound):
		code, err := v.Codes.New()
		if err != nil {
			internalError(w, "draw sign-up code", err)
			return
		}
		hash := v.Codes.Hash(signupCodeSubject, email, code)
		if err := codes.SetPendingRegistration(r.Context(), email, passwordHash, hash, time.Now().Add(v.TTL)); err != nil {
			internalError(w, "keep sign-up", err)
			return
		}
		h.deliver(r.Context(), mail.SignupCode(email, code, int(v.TTL/time.Minute)))
	default:
		internalError(w, "find user", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusAccepted, codeSentResponse{Status: "code_sent"})
}

type emailCodeInput struct {
	Email    string `json:"email"`
	Code     string `json:"code"`
	Password string `json:"password,omitempty"`
}

// handleConfirmRegistration creates the account once its sign-up code is
// right, and signs it in.
func (h *AuthHandlers) handleConfirmRegistration(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	v := h.verification
	if !enforceRateLimit(w, v.ConfirmIPRate, clientIP(r)) {
		return
	}
	var input emailCodeInput
	if !decodeStrict(w, r, &input) {
		return
	}
	email, validEmail := normalizeEmail(input.Email)
	code, validCode := normalizeEmailCode(input.Code)
	if !validEmail || !validCode {
		writeError(w, http.StatusBadRequest, "invalid_code")
		return
	}
	if !enforceRateLimit(w, v.ConfirmUserRate, "signup:"+email) {
		return
	}
	user, err := h.accountCodes().ConfirmRegistration(r.Context(), email, time.Now(), v.MaxAttempts,
		func(hash string) bool { return v.Codes.Matches(signupCodeSubject, email, code, hash) })
	switch {
	case errors.Is(err, store.ErrEmailTaken):
		writeError(w, http.StatusConflict, "email_taken")
	case errors.Is(err, store.ErrNoEmailCode), errors.Is(err, store.ErrEmailCodeMismatch),
		errors.Is(err, store.ErrEmailCodeExpired), errors.Is(err, store.ErrEmailCodeLocked):
		writeError(w, http.StatusBadRequest, "invalid_code")
	case err != nil:
		internalError(w, "confirm sign-up", err)
	default:
		slog.Info("account created", "account", user.ID)
		h.writeSession(w, http.StatusCreated, user)
	}
}

// handleForgotPassword mails a reset code when the address has an account.
// It answers the same, and as fast, when it has none.
func (h *AuthHandlers) handleForgotPassword(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	v := h.verification
	if !enforceRateLimit(w, v.SendIPRate, clientIP(r)) {
		return
	}
	var input struct {
		Email string `json:"email"`
	}
	if !decodeStrict(w, r, &input) {
		return
	}
	email, ok := normalizeEmail(input.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_email")
		return
	}
	if !enforceRateLimit(w, v.SendUserRate, "reset:"+email) {
		return
	}
	code, err := v.Codes.New()
	if err != nil {
		internalError(w, "draw reset code", err)
		return
	}
	user, err := h.accountCodes().SetPasswordResetCode(r.Context(), email, func(userID string) string {
		return v.Codes.Hash(resetCodeSubject+userID, email, code)
	}, time.Now().Add(v.TTL))
	switch {
	case errors.Is(err, store.ErrNotFound):
	case err != nil:
		internalError(w, "keep reset code", err)
		return
	default:
		slog.Info("password reset requested", "account", user.ID)
		h.deliver(r.Context(), mail.PasswordResetCode(email, code, int(v.TTL/time.Minute)))
	}
	writeJSON(w, http.StatusAccepted, codeSentResponse{Status: "code_sent"})
}

// handleResetPassword sets a new password with a reset code, ends every
// other session and signs this one in. Every kind of failed code gets the
// same answer.
func (h *AuthHandlers) handleResetPassword(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	v := h.verification
	if !enforceRateLimit(w, v.ConfirmIPRate, clientIP(r)) {
		return
	}
	var input emailCodeInput
	if !decodeStrict(w, r, &input) {
		return
	}
	email, validEmail := normalizeEmail(input.Email)
	code, validCode := normalizeEmailCode(input.Code)
	if !validEmail || !validCode {
		writeError(w, http.StatusBadRequest, "invalid_code")
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
	if !enforceRateLimit(w, v.ConfirmUserRate, "reset:"+email) {
		return
	}
	hash, err := h.passwords.Hash(input.Password)
	if err != nil {
		internalError(w, "hash password", err)
		return
	}
	user, err := h.accountCodes().ResetPassword(r.Context(), email, time.Now(), v.MaxAttempts,
		func(userID, codeEmail, codeHash string) bool {
			return v.Codes.Matches(resetCodeSubject+userID, codeEmail, code, codeHash)
		}, hash)
	switch {
	case errors.Is(err, store.ErrNotFound), errors.Is(err, store.ErrNoEmailCode), errors.Is(err, store.ErrEmailCodeMismatch),
		errors.Is(err, store.ErrEmailCodeExpired), errors.Is(err, store.ErrEmailCodeLocked):
		writeError(w, http.StatusBadRequest, "invalid_code")
	case err != nil:
		internalError(w, "reset password", err)
	default:
		if h.sessions != nil {
			h.sessions.Forget(user.ID)
		}
		slog.Info("password reset", "account", user.ID)
		h.writeSession(w, http.StatusOK, user)
	}
}
