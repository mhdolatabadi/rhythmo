package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func (f *fakeMailer) count(address string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, m := range f.sent {
		if m.To == address {
			n++
		}
	}
	return n
}

func (f *fakeMailer) lastSubject(address string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.sent) - 1; i >= 0; i-- {
		if f.sent[i].To == address {
			return f.sent[i].Subject
		}
	}
	return ""
}

func otherCode(code string) string {
	if code == "000000" {
		return "111111"
	}
	return "000000"
}

// Registering a new and an existing address answers alike (#219); the
// account only exists once the mailed code comes back.
func TestRegistrationDoesNotRevealAccounts(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	api.register(t, "taken@example.com")

	answers := map[string]string{}
	for _, email := range []string{"new@example.com", "taken@example.com"} {
		response := api.do(t, http.MethodPost, "/api/v1/auth/register", `{"email":"`+email+`","password":"correct horse"}`, "")
		answers[email] = response.Body.String()
		if response.Code != http.StatusAccepted || response.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("register %s = %d %s", email, response.Code, response.Body)
		}
	}
	if answers["new@example.com"] != answers["taken@example.com"] || strings.Contains(answers["new@example.com"], "token") {
		t.Fatalf("answers differ or sign in: %v", answers)
	}
	if got := api.mailer.lastSubject("taken@example.com"); got != "تلاش برای ثبت‌نام با ایمیل شما در ریتمو" {
		t.Fatalf("existing owner got %q", got)
	}
	// Signing in before the code is confirmed fails like a wrong password.
	expectError(t, api.do(t, http.MethodPost, "/api/v1/auth/login", `{"email":"new@example.com","password":"correct horse"}`, ""),
		http.StatusUnauthorized, "invalid_credentials")

	code := api.mailer.lastCode(t, "new@example.com")
	confirm := func(email, code string) *httptest.ResponseRecorder {
		return api.do(t, http.MethodPost, "/api/v1/auth/register/confirm", `{"email":"`+email+`","code":"`+code+`"}`, "")
	}
	expectError(t, confirm("new@example.com", otherCode(code)), http.StatusBadRequest, "invalid_code")
	expectError(t, confirm("taken@example.com", code), http.StatusBadRequest, "invalid_code")
	expectError(t, confirm("nobody@example.com", code), http.StatusBadRequest, "invalid_code")
	response := confirm(" New@Example.com ", code)
	if response.Code != http.StatusCreated {
		t.Fatalf("confirm = %d %s", response.Code, response.Body)
	}
	session := decode[sessionResponse](t, response)
	if session.Token == "" || !session.User.EmailVerified || session.User.Email != "new@example.com" {
		t.Fatalf("session = %+v", session)
	}
	expectError(t, confirm("new@example.com", code), http.StatusBadRequest, "invalid_code")
	if api.do(t, http.MethodPost, "/api/v1/auth/login", `{"email":"new@example.com","password":"correct horse"}`, "").Code != http.StatusOK {
		t.Fatal("the confirmed account cannot sign in")
	}
}

func TestSignupCodeLocksAfterWrongAttempts(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	api.do(t, http.MethodPost, "/api/v1/auth/register", `{"email":"new@example.com","password":"correct horse"}`, "")
	code := api.mailer.lastCode(t, "new@example.com")
	for range DefaultEmailCodeAttempts {
		api.do(t, http.MethodPost, "/api/v1/auth/register/confirm", `{"email":"new@example.com","code":"`+otherCode(code)+`"}`, "")
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/auth/register/confirm", `{"email":"new@example.com","code":"`+code+`"}`, ""),
		http.StatusBadRequest, "invalid_code")
	// Registering again mails a fresh code that works.
	api.do(t, http.MethodPost, "/api/v1/auth/register", `{"email":"new@example.com","password":"correct horse"}`, "")
	fresh := api.mailer.lastCode(t, "new@example.com")
	if response := api.do(t, http.MethodPost, "/api/v1/auth/register/confirm", `{"email":"new@example.com","code":"`+fresh+`"}`, ""); response.Code != http.StatusCreated {
		t.Fatalf("fresh code = %d %s", response.Code, response.Body)
	}
}

// A forgotten password is reset with an emailed code (#380); asking never
// tells whether the address has an account.
func TestPasswordReset(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{})
	oldToken, _ := api.register(t, "a@example.com")
	before := api.mailer.count("a@example.com")

	known := api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", `{"email":"A@example.com"}`, "")
	unknown := api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", `{"email":"nobody@example.com"}`, "")
	if known.Code != http.StatusAccepted || unknown.Code != known.Code || unknown.Body.String() != known.Body.String() {
		t.Fatalf("forgot = %d %s / %d %s", known.Code, known.Body, unknown.Code, unknown.Body)
	}
	if api.mailer.count("a@example.com") != before+1 || api.mailer.count("nobody@example.com") != 0 {
		t.Fatal("reset mail went to the wrong place")
	}
	code := api.mailer.lastCode(t, "a@example.com")
	reset := func(email, code, password string) *httptest.ResponseRecorder {
		return api.do(t, http.MethodPost, "/api/v1/auth/password/reset",
			`{"email":"`+email+`","code":"`+code+`","password":"`+password+`"}`, "")
	}
	expectError(t, reset("nobody@example.com", code, "a brand new secret"), http.StatusBadRequest, "invalid_code")
	expectError(t, reset("a@example.com", otherCode(code), "a brand new secret"), http.StatusBadRequest, "invalid_code")
	expectError(t, reset("a@example.com", code, "short"), http.StatusBadRequest, "invalid_password")
	expectError(t, reset("a@example.com", code, "12345678"), http.StatusBadRequest, "weak_password")

	response := reset("a@example.com", code, "a brand new secret")
	if response.Code != http.StatusOK {
		t.Fatalf("reset = %d %s", response.Code, response.Body)
	}
	session := decode[sessionResponse](t, response)
	if !session.User.EmailVerified {
		t.Fatal("a reset code proves the address, so it should count as verified")
	}
	expectError(t, api.do(t, http.MethodGet, "/api/v1/me", "", oldToken), http.StatusUnauthorized, "unauthorized")
	if api.do(t, http.MethodGet, "/api/v1/me", "", session.Token).Code != http.StatusOK {
		t.Fatal("the new session does not work")
	}
	expectError(t, reset("a@example.com", code, "another new secret"), http.StatusBadRequest, "invalid_code")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/auth/login", `{"email":"a@example.com","password":"correct horse"}`, ""),
		http.StatusUnauthorized, "invalid_credentials")
	if api.do(t, http.MethodPost, "/api/v1/auth/login", `{"email":"a@example.com","password":"a brand new secret"}`, "").Code != http.StatusOK {
		t.Fatal("the new password does not sign in")
	}
}

func TestPasswordResetIsLimitedPerAddress(t *testing.T) {
	api := newVerificationAPI(t, &EmailVerification{
		SendUserRate: NewRateLimiter(RateLimit{Requests: 1, Window: 3600e9}, 100),
	})
	api.register(t, "a@example.com")
	body := `{"email":"a@example.com"}`
	if code := api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", body, "").Code; code != http.StatusAccepted {
		t.Fatalf("first = %d", code)
	}
	expectError(t, api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", body, ""), http.StatusTooManyRequests, "rate_limited")
	// Unknown addresses are limited the same way.
	api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", `{"email":"x@example.com"}`, "")
	expectError(t, api.do(t, http.MethodPost, "/api/v1/auth/password/forgot", `{"email":"x@example.com"}`, ""), http.StatusTooManyRequests, "rate_limited")
}

func TestAccountCodesNeedVerification(t *testing.T) {
	api := newVerificationAPI(t, nil)
	for _, path := range []string{"/api/v1/auth/password/forgot", "/api/v1/auth/password/reset", "/api/v1/auth/register/confirm"} {
		if code := api.do(t, http.MethodPost, path, `{}`, "").Code; code != http.StatusNotFound && code != http.StatusMethodNotAllowed {
			t.Errorf("%s with verification off = %d", path, code)
		}
	}
}
