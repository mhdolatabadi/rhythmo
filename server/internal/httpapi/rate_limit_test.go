package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRateLimiterAllowsThenResets(t *testing.T) {
	now := time.Unix(100, 0)
	limiter := NewRateLimiter(RateLimit{Requests: 2, Window: time.Minute}, 10)
	limiter.now = func() time.Time { return now }

	if ok, _ := limiter.Allow("a"); !ok {
		t.Fatal("first request rejected")
	}
	if ok, _ := limiter.Allow("a"); !ok {
		t.Fatal("second request rejected")
	}
	if ok, retry := limiter.Allow("a"); ok || retry != time.Minute {
		t.Fatalf("third request = %v, %v", ok, retry)
	}
	if ok, _ := limiter.Allow("b"); !ok {
		t.Fatal("one key affected another")
	}
	now = now.Add(time.Minute)
	if ok, _ := limiter.Allow("a"); !ok {
		t.Fatal("window did not reset")
	}
}

func TestClientIPUsesOnlyRhythmoProxyHeader(t *testing.T) {
	request := httptest.NewRequest("GET", "/", nil)
	request.RemoteAddr = "192.0.2.10:1234"
	request.Header.Set("X-Forwarded-For", "203.0.113.99")
	if got := clientIP(request); got != "192.0.2.10" {
		t.Fatalf("trusted spoofable forwarding header: %q", got)
	}
	request.Header.Set(clientIPHeader, "203.0.113.20")
	if got := clientIP(request); got != "203.0.113.20" {
		t.Fatalf("proxy client IP = %q", got)
	}
}

func TestRateLimitIncludesRetrySecondsInJSON(t *testing.T) {
	limiter := NewRateLimiter(RateLimit{Requests: 1, Window: time.Minute}, 10)
	if !enforceRateLimit(httptest.NewRecorder(), limiter, "admin") {
		t.Fatal("first request refused")
	}
	recorder := httptest.NewRecorder()
	if enforceRateLimit(recorder, limiter, "admin") {
		t.Fatal("limit was not enforced")
	}
	var body struct {
		Error             string `json:"error"`
		RetryAfterSeconds int    `json:"retryAfterSeconds"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Error != "rate_limited" || body.RetryAfterSeconds < 1 || recorder.Header().Get("Retry-After") == "" {
		t.Fatalf("unusable retry response: %s", recorder.Body)
	}
}
