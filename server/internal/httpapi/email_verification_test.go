package httpapi

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"github.com/mhdolatabadi/rhythmo/server/internal/auth"
	"github.com/mhdolatabadi/rhythmo/server/internal/mail"
	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

// fakeMailer keeps what would have been sent.
type fakeMailer struct {
	mu   sync.Mutex
	sent []mail.Message
	err  error
}

func (f *fakeMailer) Send(_ context.Context, message mail.Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	f.sent = append(f.sent, message)
	return nil
}

// lastCode is the code in the latest email to address.
func (f *fakeMailer) lastCode(t *testing.T, address string) string {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.sent) - 1; i >= 0; i-- {
		if f.sent[i].To == address {
			for _, line := range strings.Split(f.sent[i].Text, "\n") {
				if len(line) == auth.EmailCodeDigits && strings.Trim(line, "0123456789") == "" {
					return line
				}
			}
		}
	}
	t.Fatalf("no code was mailed to %s", address)
	return ""
}

type verificationAPI struct {
	testAPI
	mailer *fakeMailer
	linker *fakeLinker
	users  *store.Users
	auth   *AuthHandlers
}

func newVerificationAPI(t *testing.T, verification *EmailVerification) verificationAPI {
	t.Helper()
	pool := collabTestPool(t)
	users := store.NewUsers(pool)
	secret := []byte(strings.Repeat("k", auth.MinSecretBytes))
	tokens, err := auth.NewTokens(secret, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	sessions := auth.NewSessions(func(ctx context.Context, id string) (int64, error) {
		epoch, err := users.SessionEpoch(ctx, id)
		if errors.Is(err, store.ErrNotFound) {
			return 0, auth.ErrNoAccount
		}
		return epoch, err
	}, time.Minute, 100)
	tokens.WithSessions(sessions)
	authHandlers, err := NewAuthHandlers(users, auth.Passwords{Cost: bcrypt.MinCost}, tokens, AuthRateLimiters{})
	if err != nil {
		t.Fatal(err)
	}
	authHandlers.WithSessionRevocation(users, sessions)
	authHandlers.WithAdmins([]string{"boss@example.com"})
	mailer := &fakeMailer{}
	if verification != nil {
		codes, err := auth.NewEmailCodes(secret)
		if err != nil {
			t.Fatal(err)
		}
		verification.Store, verification.Mailer, verification.Codes = users, mailer, codes
		verification.syncMail = true
		authHandlers.WithEmailVerification(*verification)
	}
	gate := authHandlers.EmailGate()
	linker := &fakeLinker{}
	tracks := NewTrackHandlers(&memoryTracks{}, &fakeObjects{objects: map[string][]byte{}}, tokens, UploadLimits{
		MaxFileBytes: testMaxUpload, MaxOwnerBytes: testOwnerQuota, MaxPending: testMaxPending, Enabled: true,
	}).WithEmailGate(gate)
	bots := NewBotHandlers(linker, &fakeSender{}, tokens, []Bot{{Provider: "bale", Name: "Bale"}}, nil, nil).WithEmailGate(gate)
	links := NewLinkImportHandlers(&fakeLinkImporter{}, tokens, nil).WithEmailGate(gate)
	playlists := store.NewPlaylists(pool)
	playlistHandlers := NewPlaylistHandlers(playlists, tokens).
		WithSharing(playlists, fixedPresigner{}, SavePolicy{Objects: noCopies{}, MaxOwnerBytes: testOwnerQuota, Enabled: true}).
		WithEmailGate(gate)
	handler := NewHandler(Config{
		Auth: authHandlers, Admin: NewAdminHandlers(authHandlers, users),
		Tracks: tracks, Playlists: playlistHandlers, Bots: bots, LinkImports: links,
	})
	return verificationAPI{
		testAPI: testAPI{handler: handler, tokens: tokens},
		mailer:  mailer, linker: linker, users: users, auth: authHandlers,
	}
}

// register signs up through the API when verification is off. With it on,
// it makes an account that has not verified its address yet, as accounts
// from before sign-up codes (#219) are, mails it a code and signs it in.
func (a verificationAPI) register(t *testing.T, email string) (string, userResponse) {
	t.Helper()
	if a.auth.verification != nil {
		hash, err := a.auth.passwords.Hash("correct horse")
		if err != nil {
			t.Fatal(err)
		}
		user, err := a.users.Create(context.Background(), email, hash)
		if err != nil {
			t.Fatal(err)
		}
		a.auth.afterRegister(context.Background(), user)
	}
	path := map[bool]string{true: "/api/v1/auth/login", false: "/api/v1/auth/register"}[a.auth.verification != nil]
	response := a.do(t, http.MethodPost, path, `{"email":"`+email+`","password":"correct horse"}`, "")
	if response.Code != http.StatusCreated && response.Code != http.StatusOK {
		t.Fatalf("register: %d %s", response.Code, response.Body)
	}
	session := decode[sessionResponse](t, response)
	return session.Token, session.User
}

// gated calls each endpoint that needs a verified email and returns their
// statuses.
func (a verificationAPI) gated(t *testing.T, token string) []int {
	t.Helper()
	var codes []int
	for _, call := range []struct{ method, path, body string }{
		{http.MethodPost, "/api/v1/tracks/uploads", `{"fileName":"song.mp3","sizeBytes":1000}`},
		{http.MethodPost, "/api/v1/bots/link-code", ``},
		{http.MethodPost, "/api/v1/bots/bale/send", `{"trackId":"t1"}`},
		{http.MethodPost, "/api/v1/imports/link", `{"url":"https://example.com/a.mp3"}`},
	} {
		codes = append(codes, a.do(t, call.method, call.path, call.body, token).Code)
	}
	return codes
}

func TestEmailVerificationFlow(t *testing.T) {
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previous) })

	api := newVerificationAPI(t, &EmailVerification{})
	token, user := api.register(t, "new@example.com")
	if user.EmailVerified || user.Verified {
		t.Fatalf("a new account is verified: %+v", user)
	}
	code := api.mailer.lastCode(t, "new@example.com")

	// Unverified accounts may listen but not use what is gated.
	for i, status := range api.gated(t, token) {
		if status != http.StatusForbidden {
			t.Fatalf("gated call %d = %d before verification", i, status)
		}
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/tracks/uploads", `{"fileName":"song.mp3","sizeBytes":1000}`, token),
		http.StatusForbidden, "email_unverified")

	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	response := api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+wrong+`"}`, token)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"attemptsLeft":4`) {
		t.Fatalf("wrong code: %d %s", response.Code, response.Body)
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"12ab56"}`, token),
		http.StatusBadRequest, "invalid_code")

	// Typed on a Persian keyboard, with a space.
	persian := []rune(code)
	for i, r := range persian {
		persian[i] = '۰' + r - '0'
	}
	typed := string(persian[:3]) + " " + string(persian[3:])
	response = api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+typed+`"}`, token)
	if response.Code != http.StatusOK || !decode[userResponse](t, response).EmailVerified {
		t.Fatalf("right code: %d %s", response.Code, response.Body)
	}
	me := decode[userResponse](t, api.do(t, http.MethodGet, "/api/v1/me", "", token))
	if !me.EmailVerified || me.Verified {
		t.Fatalf("after verifying: %+v; the admin badge must stay separate", me)
	}
	for i, status := range api.gated(t, token) {
		if status == http.StatusForbidden {
			t.Fatalf("gated call %d still refused after verification", i)
		}
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token), http.StatusConflict, "email_already_verified")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+code+`"}`, token), http.StatusConflict, "email_already_verified")
	expectError(t, api.do(t, http.MethodPut, "/api/v1/me/email", `{"email":"other@example.com"}`, token), http.StatusConflict, "email_already_verified")

	if strings.Contains(logs.String(), code) || strings.Contains(logs.String(), wrong) {
		t.Fatalf("a code reached the logs:\n%s", logs.String())
	}
}

func TestEmailCodeAttemptsAndResend(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{
		SendUserRate: NewRateLimiter(RateLimit{Requests: 2, Window: time.Hour}, 100),
	})
	token, _ := api.register(t, "a@example.com")
	first := api.mailer.lastCode(t, "a@example.com")
	wrong := "000000"
	if first == wrong {
		wrong = "111111"
	}
	for range DefaultEmailCodeAttempts {
		api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+wrong+`"}`, token)
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+first+`"}`, token),
		http.StatusConflict, "code_locked")

	response := api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token)
	if response.Code != http.StatusAccepted || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("resend: %d %s", response.Code, response.Body)
	}
	expires := decode[emailCodeResponse](t, response).ExpiresAt
	if until := time.Until(expires); until < 14*time.Minute || until > 15*time.Minute {
		t.Fatalf("code lives %s; want 15 minutes", until)
	}
	second := api.mailer.lastCode(t, "a@example.com")
	// The account's limit is two codes an hour; registration's doesn't count.
	api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token)
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token), http.StatusTooManyRequests, "rate_limited")

	third := api.mailer.lastCode(t, "a@example.com")
	if second != third {
		if api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+second+`"}`, token).Code == http.StatusOK {
			t.Fatal("a replaced code still works")
		}
	}
	if response := api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+third+`"}`, token); response.Code != http.StatusOK {
		t.Fatalf("latest code: %d %s", response.Code, response.Body)
	}
}

func TestResendIsLimitedPerIP(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{
		SendIPRate: NewRateLimiter(RateLimit{Requests: 1, Window: time.Hour}, 100),
	})
	first, _ := api.register(t, "a@example.com")
	second, _ := api.register(t, "b@example.com")
	if code := api.do(t, http.MethodPost, "/api/v1/me/email/code", "", first).Code; code != http.StatusAccepted {
		t.Fatalf("first resend = %d", code)
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/code", "", second), http.StatusTooManyRequests, "rate_limited")
}

func TestChangeUnverifiedEmail(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	token, _ := api.register(t, "typo@exmaple.com")
	api.register(t, "taken@example.com")
	old := api.mailer.lastCode(t, "typo@exmaple.com")

	expectError(t, api.do(t, http.MethodPut, "/api/v1/me/email", `{"email":"taken@example.com"}`, token), http.StatusConflict, "email_taken")
	expectError(t, api.do(t, http.MethodPut, "/api/v1/me/email", `{"email":"not an address"}`, token), http.StatusBadRequest, "invalid_email")
	response := api.do(t, http.MethodPut, "/api/v1/me/email", `{"email":" Right@Example.com "}`, token)
	if response.Code != http.StatusOK {
		t.Fatalf("change: %d %s", response.Code, response.Body)
	}
	changed := decode[changeEmailResponse](t, response)
	if changed.User.Email != "right@example.com" || changed.User.EmailVerified || !changed.CodeSent {
		t.Fatalf("change = %+v", changed)
	}
	code := api.mailer.lastCode(t, "right@example.com")
	if old != code {
		expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+old+`"}`, token), http.StatusBadRequest, "wrong_code")
	}
	if response := api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+code+`"}`, token); response.Code != http.StatusOK {
		t.Fatalf("verify the new address: %d %s", response.Code, response.Body)
	}
}

func TestMailFailureKeepsRegistrationWorking(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	api.mailer.err = errors.New("relay down")
	token, user := api.register(t, "a@example.com")
	if user.EmailVerified {
		t.Fatal("verified without a code")
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token), http.StatusBadGateway, "email_send_failed")
	response := api.do(t, http.MethodPut, "/api/v1/me/email", `{"email":"b@example.com"}`, token)
	if response.Code != http.StatusOK || decode[changeEmailResponse](t, response).CodeSent {
		t.Fatalf("change while mail is down: %d %s", response.Code, response.Body)
	}
}

func TestVerificationOffWithoutSMTP(t *testing.T) {
	api := newVerificationAPI(t, nil)
	token, user := api.register(t, "a@example.com")
	if !user.EmailVerified {
		t.Fatal("with verification off, accounts must count as verified")
	}
	for i, status := range api.gated(t, token) {
		if status == http.StatusForbidden {
			t.Fatalf("gated call %d refused with verification off", i)
		}
	}
	if code := api.do(t, http.MethodPost, "/api/v1/me/email/code", "", token).Code; code != http.StatusNotFound && code != http.StatusMethodNotAllowed {
		t.Fatalf("resend with verification off = %d", code)
	}
	if len(api.mailer.sent) != 0 {
		t.Fatal("mail was sent with verification off")
	}
}

func TestAdminNeedsAVerifiedEmail(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	token, user := api.register(t, "boss@example.com")
	if user.IsAdmin {
		t.Fatal("an allowlisted address is admin before it is verified")
	}
	expectError(t, api.do(t, http.MethodGet, "/api/v1/admin/accounts", "", token), http.StatusForbidden, "admin_required")
	code := api.mailer.lastCode(t, "boss@example.com")
	verified := decode[userResponse](t, api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+code+`"}`, token))
	if !verified.IsAdmin {
		t.Fatal("a verified allowlisted address is not admin")
	}
}

func TestOnlyVerifiedAccountsListPlaylistsPublicly(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	token, _ := api.register(t, "a@example.com")
	response := api.do(t, http.MethodPost, "/api/v1/playlists", `{"name":"شب"}`, token)
	if response.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", response.Code, response.Body)
	}
	id := decode[struct {
		ID string `json:"id"`
	}](t, response).ID
	// A link to the playlist still works for unverified accounts.
	if response := api.do(t, http.MethodPost, "/api/v1/playlists/"+id+"/share", `{"public":false}`, token); response.Code != http.StatusOK {
		t.Fatalf("link-only share: %d %s", response.Code, response.Body)
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/playlists/"+id+"/share", `{"public":true}`, token),
		http.StatusForbidden, "email_unverified")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/shared-playlists/"+strings.Repeat("a", 22)+"/save", ``, token),
		http.StatusForbidden, "email_unverified")

	code := api.mailer.lastCode(t, "a@example.com")
	api.do(t, http.MethodPost, "/api/v1/me/email/verify", `{"code":"`+code+`"}`, token)
	response = api.do(t, http.MethodPost, "/api/v1/playlists/"+id+"/share", `{"public":true}`, token)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"public":true`) {
		t.Fatalf("public share after verifying: %d %s", response.Code, response.Body)
	}
}
