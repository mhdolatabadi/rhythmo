// Package bot lets people sign in to rhythmo and import audio from messenger
// bots. It knows nothing about any one messenger: each is a Provider, and the
// same commands, login flow and import pipeline serve all of them.
package bot

import (
	"context"
	"errors"
	"io"
)

// Update is one incoming message, already reduced to what rhythmo uses.
type Update struct {
	// ID is the provider's update ID; redeliveries repeat it.
	ID      string
	ChatID  string
	Private bool
	// Channel is a post in a channel the bot administers; ChatTitle is
	// the channel's name.
	Channel   bool
	ChatTitle string
	MessageID string
	Text      string
	File      *File
}

// File is an audio file or document attached to a message.
type File struct {
	ID        string
	Name      string
	MIMEType  string
	SizeBytes int64
	// Title and Performer come from the messenger's audio metadata, if any.
	Title     string
	Performer string
}

// Provider is one messenger's Bot API.
type Provider interface {
	// Name identifies the provider in storage and URLs, for example "bale".
	Name() string
	Send(ctx context.Context, chatID, text string) error
	// Open streams a file. The size is the provider's, which the import trusts
	// only as far as storage verifies it.
	Open(ctx context.Context, fileID string) (io.ReadCloser, int64, error)
	// MaxDownloadBytes is the largest file the provider lets bots download.
	MaxDownloadBytes() int64
	// SendAudio posts audio to a chat and returns the provider's file ID for
	// it, which a later SendAudio can pass instead of the content.
	SendAudio(ctx context.Context, chatID string, audio OutgoingAudio) (string, error)
	// MaxUploadBytes is the largest file the provider lets bots upload.
	MaxUploadBytes() int64
}

// OutgoingAudio is audio for a bot to send: either a FileID the provider
// already has, or Body with exactly Size bytes.
type OutgoingAudio struct {
	FileID    string
	FileName  string
	Body      io.Reader
	Size      int64
	Title     string
	Performer string
}

// ErrFileTooLarge is returned for files the provider will not serve or accept.
var ErrFileTooLarge = errors.New("file is too large for the provider")
