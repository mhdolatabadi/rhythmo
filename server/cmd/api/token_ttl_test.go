package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

// A login lasts a year unless AUTH_TOKEN_TTL says otherwise (#398), and the
// deployment files default to the same year.
func TestTokensLastAYearByDefault(t *testing.T) {
	if defaultTokenTTL != 365*24*time.Hour {
		t.Fatalf("default token TTL = %s", defaultTokenTTL)
	}
	for _, raw := range []string{"", "  "} {
		if ttl, err := tokenTTLFromEnv(raw); err != nil || ttl != defaultTokenTTL {
			t.Fatalf("tokenTTLFromEnv(%q) = %s, %v", raw, ttl, err)
		}
	}
	if ttl, err := tokenTTLFromEnv("720h"); err != nil || ttl != 30*24*time.Hour {
		t.Fatalf("override = %s, %v", ttl, err)
	}
	for _, bad := range []string{"soon", "0", "-1h"} {
		if _, err := tokenTTLFromEnv(bad); err == nil {
			t.Errorf("tokenTTLFromEnv(%q) accepted", bad)
		}
	}
	for file, setting := range map[string]string{
		"../../../deploy/compose.yaml": "AUTH_TOKEN_TTL: ${AUTH_TOKEN_TTL:-8760h}",
		"../../../deploy/.env.example": "AUTH_TOKEN_TTL=8760h\n",
	} {
		content, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(content), setting) {
			t.Errorf("%s does not default AUTH_TOKEN_TTL to a year", file)
		}
	}
}
