package httpapi

import (
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"sync"
	"time"
)

const clientIPHeader = "X-rhythmo-Client-IP"

type RateLimit struct {
	Requests int
	Window   time.Duration
}

type rateBucket struct {
	count int
	reset time.Time
}

// RateLimiter is a bounded in-memory fixed-window limiter. Limits are local to
// one API process; rhythmo currently deploys one API replica.
type RateLimiter struct {
	mu         sync.Mutex
	limit      RateLimit
	maxEntries int
	entries    map[string]rateBucket
	now        func() time.Time
	// openWhenFull lets new keys through once the table is full instead of
	// refusing them, for limiters whose keys a client chooses (such as an
	// email) and that sit behind a per-IP limiter (#215).
	openWhenFull bool
}

func NewRateLimiter(limit RateLimit, maxEntries int) *RateLimiter {
	return &RateLimiter{
		limit: limit, maxEntries: maxEntries,
		entries: make(map[string]rateBucket), now: time.Now,
	}
}

// OpenWhenFull makes the limiter allow untracked keys while its table is
// full. Use it where filling the table with made-up keys must not lock
// everyone else out.
func (l *RateLimiter) OpenWhenFull() *RateLimiter {
	l.openWhenFull = true
	return l
}

func (l *RateLimiter) Allow(key string) (bool, time.Duration) {
	if l == nil {
		return true, 0
	}
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()

	bucket, exists := l.entries[key]
	if !exists || !now.Before(bucket.reset) {
		if !exists && len(l.entries) >= l.maxEntries {
			for candidate, value := range l.entries {
				if !now.Before(value.reset) {
					delete(l.entries, candidate)
				}
			}
			if len(l.entries) >= l.maxEntries {
				if l.openWhenFull {
					return true, 0
				}
				return false, l.limit.Window
			}
		}
		l.entries[key] = rateBucket{count: 1, reset: now.Add(l.limit.Window)}
		return true, 0
	}
	if bucket.count >= l.limit.Requests {
		return false, bucket.reset.Sub(now)
	}
	bucket.count++
	l.entries[key] = bucket
	return true, 0
}

func enforceRateLimit(w http.ResponseWriter, limiter *RateLimiter, key string) bool {
	allowed, retryAfter := limiter.Allow(key)
	if allowed {
		return true
	}
	seconds := int64((retryAfter + time.Second - 1) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.FormatInt(seconds, 10))
	writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate_limited", "retryAfterSeconds": seconds})
	return false
}

// clientIP is the client's identity for per-IP rate limits. It trusts only a
// private header overwritten by rhythmo's Caddy config; RemoteAddr remains the
// safe fallback for local development and tests. An IPv6 client is limited
// by its /64, since one host usually controls a whole /64 (#215).
func clientIP(r *http.Request) string {
	if addr, err := netip.ParseAddr(r.Header.Get(clientIPHeader)); err == nil {
		return rateLimitAddress(addr)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if addr, parseErr := netip.ParseAddr(host); err == nil && parseErr == nil {
		return rateLimitAddress(addr)
	}
	return "unknown"
}

func rateLimitAddress(addr netip.Addr) string {
	addr = addr.WithZone("").Unmap()
	if addr.Is4() {
		return addr.String()
	}
	return netip.PrefixFrom(addr, 64).Masked().String()
}
