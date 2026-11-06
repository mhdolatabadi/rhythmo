package bot

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
	"unicode"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

var (
	ErrBadCode = errors.New("link code is wrong or expired")
	ErrLocked  = errors.New("too many wrong link codes")
)

type LinkStore interface {
	Chat(ctx context.Context, provider, chatID string) (store.BotChat, error)
	Unlink(ctx context.Context, provider, chatID string) error
	CreateLinkCode(ctx context.Context, userID string, hash []byte, expiresAt time.Time) error
	RedeemLinkCode(ctx context.Context, provider, chatID string, hash []byte, now time.Time, maxFailures int, window time.Duration) (string, error)
	CreateChannelCode(ctx context.Context, userID, playlistID string, hash []byte, expiresAt time.Time) error
	RedeemChannelCode(ctx context.Context, provider, chatID, title string, hash []byte, now time.Time, maxFailures int, window time.Duration) (store.BotChannel, error)
	LinkedProviders(ctx context.Context, userID string, since time.Time) ([]string, error)
}

type LinkLimits struct {
	CodeTTL time.Duration
	// MaxFailures wrong codes from one chat within FailureWindow lock it out
	// until the window passes.
	MaxFailures   int
	FailureWindow time.Duration
	SessionTTL    time.Duration
}

var DefaultLinkLimits = LinkLimits{
	CodeTTL: 10 * time.Minute, MaxFailures: 5, FailureWindow: time.Hour,
	SessionTTL: 180 * 24 * time.Hour,
}

// Linker connects bot chats to rhythmo accounts. Someone signed in to the app
// asks for a short-lived one-time code and sends it to the bot, so proving
// who they are never happens in the chat and needs no password or email.
// Only an HMAC of each code is stored.
type Linker struct {
	store  LinkStore
	key    []byte
	limits LinkLimits
	now    func() time.Time
}

func NewLinker(s LinkStore, key []byte, limits LinkLimits) (*Linker, error) {
	if len(key) < 32 {
		return nil, errors.New("link code key must be at least 32 bytes")
	}
	return &Linker{store: s, key: key, limits: limits, now: time.Now}, nil
}

// NewCode issues a code for the user, replacing any earlier one.
func (l *Linker) NewCode(ctx context.Context, userID string) (string, time.Time, error) {
	expiresAt := l.now().Add(l.limits.CodeTTL)
	for range 5 {
		code, err := newCode()
		if err != nil {
			return "", time.Time{}, err
		}
		err = l.store.CreateLinkCode(ctx, userID, l.hash(code), expiresAt)
		if errors.Is(err, store.ErrCodeCollision) {
			continue
		}
		return code, expiresAt, err
	}
	return "", time.Time{}, errors.New("could not pick an unused link code")
}

// NewChannelCode issues a code that links a messenger channel to the
// playlist, which the user must own or administer: store.ErrNotFound
// otherwise. It replaces the user's earlier code for that playlist.
func (l *Linker) NewChannelCode(ctx context.Context, userID, playlistID string) (string, time.Time, error) {
	expiresAt := l.now().Add(l.limits.CodeTTL)
	for range 5 {
		code, err := newCode()
		if err != nil {
			return "", time.Time{}, err
		}
		err = l.store.CreateChannelCode(ctx, userID, playlistID, l.hash(code), expiresAt)
		if errors.Is(err, store.ErrCodeCollision) {
			continue
		}
		return code, expiresAt, err
	}
	return "", time.Time{}, errors.New("could not pick an unused link code")
}

// RedeemChannel links the messenger channel to the playlist a channel code
// was issued for. store.ErrNotFound means its issuer no longer runs it.
func (l *Linker) RedeemChannel(ctx context.Context, provider, chatID, title, input string) (store.BotChannel, error) {
	code, ok := NormalizeCode(input)
	if !ok {
		return store.BotChannel{}, ErrBadCode
	}
	link, err := l.store.RedeemChannelCode(ctx, provider, chatID, title, l.hash(code), l.now(),
		l.limits.MaxFailures, l.limits.FailureWindow)
	switch {
	case errors.Is(err, store.ErrCodeInvalid):
		return store.BotChannel{}, ErrBadCode
	case errors.Is(err, store.ErrCodeAttempts):
		return store.BotChannel{}, ErrLocked
	}
	return link, err
}

// Redeem links the chat to the account that issued the code.
func (l *Linker) Redeem(ctx context.Context, provider, chatID, input string) (string, error) {
	code, ok := NormalizeCode(input)
	if !ok {
		return "", ErrBadCode
	}
	userID, err := l.store.RedeemLinkCode(ctx, provider, chatID, l.hash(code), l.now(),
		l.limits.MaxFailures, l.limits.FailureWindow)
	switch {
	case errors.Is(err, store.ErrCodeInvalid):
		return "", ErrBadCode
	case errors.Is(err, store.ErrCodeAttempts):
		return "", ErrLocked
	}
	return userID, err
}

// Session returns the chat's linked user, unlinking expired sessions.
func (l *Linker) Session(ctx context.Context, provider, chatID string) (store.BotChat, bool, error) {
	chat, err := l.store.Chat(ctx, provider, chatID)
	if err != nil || chat.UserID == nil {
		return chat, false, err
	}
	if chat.LinkedAt != nil && l.now().Sub(*chat.LinkedAt) > l.limits.SessionTTL {
		if err := l.store.Unlink(ctx, provider, chatID); err != nil {
			return chat, false, err
		}
		chat.UserID = nil
		return chat, false, nil
	}
	return chat, true, nil
}

// LinkedProviders lists the bots the user has a live chat link with.
func (l *Linker) LinkedProviders(ctx context.Context, userID string) ([]string, error) {
	return l.store.LinkedProviders(ctx, userID, l.now().Add(-l.limits.SessionTTL))
}

// SessionTTL is how long a chat link lasts.
func (l *Linker) SessionTTL() time.Duration { return l.limits.SessionTTL }

func (l *Linker) Unlink(ctx context.Context, provider, chatID string) error {
	return l.store.Unlink(ctx, provider, chatID)
}

func (l *Linker) hash(code string) []byte {
	mac := hmac.New(sha256.New, l.key)
	mac.Write([]byte(code))
	return mac.Sum(nil)
}

// CodeDigits is the length of a link code: short enough to type, and with
// codes living ten minutes and five wrong tries per chat an hour, far too
// many to guess.
const CodeDigits = 8

func newCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(100_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%08d", n.Int64()), nil
}

// NormalizeCode accepts Persian and Arabic-Indic digits, spaces and dashes,
// as typed on a Persian keyboard or copied from the app.
func NormalizeCode(input string) (string, bool) {
	var b strings.Builder
	for _, r := range input {
		switch {
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		case r >= '۰' && r <= '۹':
			b.WriteRune('0' + r - '۰')
		case r >= '٠' && r <= '٩':
			b.WriteRune('0' + r - '٠')
		case unicode.IsSpace(r) || r == '-':
		default:
			return "", false
		}
	}
	return b.String(), b.Len() == CodeDigits
}

// MaskEmail shows enough of an address to recognize it: "m***@gmail.com".
func MaskEmail(email string) string {
	local, domain, ok := strings.Cut(email, "@")
	if !ok || local == "" {
		return "***"
	}
	return string([]rune(local)[:1]) + "***@" + domain
}
