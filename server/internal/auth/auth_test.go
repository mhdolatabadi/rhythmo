package auth

import (
	"errors"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

var testSecret = []byte(strings.Repeat("s", MinSecretBytes))

func TestPasswordHashRoundTrip(t *testing.T) {
	passwords := Passwords{Cost: bcrypt.MinCost}
	hash, err := passwords.Hash("correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(hash, "correct horse") {
		t.Fatal("hash contains the plaintext password")
	}
	if err := passwords.Verify(hash, "correct horse"); err != nil {
		t.Fatalf("expected match, got %v", err)
	}
	if err := passwords.Verify(hash, "wrong horse"); !errors.Is(err, ErrPasswordMismatch) {
		t.Fatalf("expected mismatch, got %v", err)
	}
}

func TestTokenRoundTrip(t *testing.T) {
	tokens, err := NewTokens(testSecret, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	token, expiresAt, err := tokens.Issue("user-1")
	if err != nil {
		t.Fatal(err)
	}
	if time.Until(expiresAt) <= 0 {
		t.Fatalf("token already expired at %v", expiresAt)
	}
	userID, err := tokens.Verify(token)
	if err != nil || userID != "user-1" {
		t.Fatalf("expected user-1, got %q (%v)", userID, err)
	}
}

func TestExpiredTokenIsRejected(t *testing.T) {
	tokens, _ := NewTokens(testSecret, time.Hour)
	token, _, _ := tokens.Issue("user-1")
	tokens.now = func() time.Time { return time.Now().Add(2 * time.Hour) }
	if _, err := tokens.Verify(token); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("expected ErrInvalidToken, got %v", err)
	}
}

func TestTokenFromAnotherSecretIsRejected(t *testing.T) {
	issuer, _ := NewTokens(testSecret, time.Hour)
	verifier, _ := NewTokens([]byte(strings.Repeat("x", MinSecretBytes)), time.Hour)
	token, _, _ := issuer.Issue("user-1")
	if _, err := verifier.Verify(token); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("expected ErrInvalidToken, got %v", err)
	}
}

func TestUnsignedTokenIsRejected(t *testing.T) {
	tokens, _ := NewTokens(testSecret, time.Hour)
	// {"alg":"none"} header with a valid-looking payload and no signature.
	token := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJpc3MiOiJuYWZpciIsInN1YiI6InVzZXItMSIsImV4cCI6NDEwMjQ0NDgwMH0."
	if _, err := tokens.Verify(token); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("expected ErrInvalidToken, got %v", err)
	}
}

func TestShortSecretIsRejected(t *testing.T) {
	if _, err := NewTokens([]byte("short"), time.Hour); err == nil {
		t.Fatal("expected an error for a short secret")
	}
}

func TestWeakPasswords(t *testing.T) {
	for _, password := range []string{
		"password", "PASSWORD", "12345678", "qwertyuiop", "iloveyou", " 123456789 ",
		"aaaaaaaa", "۱۱۱۱۱۱۱۱", "sara.k@example.com", "SARA.K", "sara.k",
	} {
		if !WeakPassword(password, "sara.k@example.com") {
			t.Errorf("%q should be weak", password)
		}
	}
	for _, password := range []string{"correct horse battery", "Tq7#vL2m", "ریتموی من ۱۴۰۵", "aaaaaaab"} {
		if WeakPassword(password, "sara.k@example.com") {
			t.Errorf("%q should be accepted", password)
		}
	}
	if WeakPassword("", "") {
		t.Error("an empty password is the length rule's job")
	}
}

func TestCommonPasswordListIsLoaded(t *testing.T) {
	if len(commonPasswords) < 2000 {
		t.Fatalf("only %d common passwords loaded", len(commonPasswords))
	}
	for password := range commonPasswords {
		if len(password) < MinPasswordLength || password != strings.ToLower(password) {
			t.Fatalf("list entry %q is not a lower-cased password of %d+ characters", password, MinPasswordLength)
		}
	}
}

// A year-long login (#398) still works a day before its year is up and is
// refused after it.
func TestYearLongTokenExpiresAfterAYear(t *testing.T) {
	year := 365 * 24 * time.Hour
	tokens, err := NewTokens([]byte(strings.Repeat("k", MinSecretBytes)), year)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	tokens.now = func() time.Time { return start }
	token, expiresAt, err := tokens.Issue("user-1")
	if err != nil || !expiresAt.Equal(start.Add(year)) {
		t.Fatalf("issue = %s, %v", expiresAt, err)
	}
	tokens.now = func() time.Time { return start.Add(year - 24*time.Hour) }
	if id, err := tokens.Verify(token); err != nil || id != "user-1" {
		t.Fatalf("near the end of the year: %q, %v", id, err)
	}
	tokens.now = func() time.Time { return start.Add(year + time.Minute) }
	if _, err := tokens.Verify(token); err == nil {
		t.Fatal("a token past its year was accepted")
	}
}
