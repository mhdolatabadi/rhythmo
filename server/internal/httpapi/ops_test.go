package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
)

type fakeHealth []bot.BotHealth

func (f fakeHealth) Health(context.Context) ([]bot.BotHealth, error) { return f, nil }

func TestOpsBotsNeedsTheOperatorToken(t *testing.T) {
	token := strings.Repeat("o", 32)
	handler := NewHandler(Config{Ops: NewOpsHandlers(token, fakeHealth{
		{Provider: "bale", Problems: []string{}},
		{Provider: "telegram", Problems: []string{"webhook not registered"}},
	})})

	for name, header := range map[string]string{"none": "", "wrong": "Bearer " + strings.Repeat("x", 32)} {
		request := httptest.NewRequest(http.MethodGet, "/api/v1/ops/bots", nil)
		if header != "" {
			request.Header.Set("Authorization", header)
		}
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusNotFound {
			t.Fatalf("%s token = %d", name, response.Code)
		}
	}

	request := httptest.NewRequest(http.MethodGet, "/api/v1/ops/bots", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	var body botHealthResponse
	json.NewDecoder(response.Body).Decode(&body)
	if response.Code != http.StatusOK || body.Healthy || len(body.Bots) != 2 {
		t.Fatalf("ops = %d %+v", response.Code, body)
	}
}

func TestOpsTranscriptionRequiresTokenAndShowsAggregateHealth(t *testing.T) {
	token := strings.Repeat("t", 32)
	calls := 0
	ops := NewOpsHandlers(token, nil).WithTranscription(
		func(context.Context) (TranscriptionHealth, error) {
			calls++
			return TranscriptionHealth{
				Healthy: false, ModelReady: false, Queued: 2,
				Processing: 1, Failed: 3, OldestPendingSeconds: 120,
			}, nil
		})
	handler := NewHandler(Config{Ops: ops})
	for _, authorization := range []string{"", "Bearer " + strings.Repeat("x", 32)} {
		request := httptest.NewRequest(http.MethodGet, "/api/v1/ops/transcription", nil)
		request.Header.Set("Authorization", authorization)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusNotFound {
			t.Fatalf("unauthorized transcription status: %d", response.Code)
		}
	}
	if calls != 0 {
		t.Fatal("unauthorized requests reached the probe")
	}
	request := httptest.NewRequest(http.MethodGet, "/api/v1/ops/transcription", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	var result TranscriptionHealth
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || result.Healthy || result.ModelReady ||
		result.Queued != 2 || result.Processing != 1 || result.Failed != 3 ||
		result.OldestPendingSeconds != 120 || calls != 1 {
		t.Fatalf("wrong transcription health: %d %+v calls %d", response.Code, result, calls)
	}
}

func TestOpsIsNotServedWithoutAToken(t *testing.T) {
	response := httptest.NewRecorder()
	NewHandler(Config{}).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/ops/bots", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("ops without config = %d", response.Code)
	}
}
