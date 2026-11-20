// Package transcription runs a persistent queue against a private speech recognition service.
package transcription

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var ErrBusy = errors.New("transcription queue full")

const MaxFileBytes int64 = 200 << 20
// The server accepts recordings up to two hours: the result must not be
// rejected just because a long Persian lecture exceeds 64 KiB.
const MaxPlainTextBytes = 512 << 10
const MaxTimedTextBytes = 1024 << 10
const maxTranscriptResponseBytes = MaxPlainTextBytes + MaxTimedTextBytes + 2048
const leaseDuration = 2 * time.Hour

type Result struct {
	State  string `json:"state"`
	Plain  string `json:"plain"`
	Synced string `json:"synced"`
}
type Job struct {
	ID, Key string
	Size    int64
	Lease   time.Time
}
type Store interface {
	Status(context.Context, string) (Result, error)
	Queue(context.Context, string, string) error
	Claim(context.Context, time.Duration) (Job, bool, error)
	Finish(context.Context, Job, Result) error
}
type Objects interface {
	Open(context.Context, string) (io.ReadCloser, error)
}
type Worker struct {
	Store           Store
	objects         Objects
	endpoint, token string
	client          *http.Client
}

func New(s Store, objects Objects, endpoint, token string) (*Worker, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("invalid transcription URL")
	}
	if len(token) < 32 {
		return nil, errors.New("transcription token needs at least 32 characters")
	}
	return &Worker{s, objects, strings.TrimRight(endpoint, "/"), token, &http.Client{Timeout: 110 * time.Minute, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (w *Worker) ready(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, w.endpoint+"/health", nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "Bearer "+w.token)
	resp, err := w.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
// Ready probes the authenticated inference service with a short deadline.
// A running container is not necessarily a usable transcription model.
func (w *Worker) Ready(ctx context.Context) bool { return w.ready(ctx) }

func (w *Worker) Run(ctx context.Context) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	wasReady := false
	for {
		if ctx.Err() != nil {
			return
		}
		if !w.ready(ctx) {
			if wasReady {
				slog.Warn("transcription service became unavailable")
			}
			wasReady = false
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			continue
		}
		if !wasReady {
			slog.Info("transcription service ready")
			wasReady = true
		}
		j, ok, err := w.Store.Claim(ctx, leaseDuration)
		if err != nil {
			slog.Error("claim transcription failed", "error", err)
		}
		if ok {
			w.process(ctx, j)
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (w *Worker) process(ctx context.Context, j Job) {
	r, err := w.extract(ctx, j)
	if ctx.Err() != nil {
		return
	} // Leave the lease for recovery after restart.
	if err != nil {
		r = Result{State: "failed"}
		// Preserve the cause for operators without logging any audio or
		// generated transcript. Previously every failure looked identical.
		slog.Warn("transcription failed", "track", j.ID, "error", err)
	}
	finishCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := w.Store.Finish(finishCtx, j, r); err != nil {
		slog.Error("save transcription failed", "error", err)
	}
}
func (w *Worker) extract(ctx context.Context, j Job) (Result, error) {
	if j.Size <= 0 || j.Size > MaxFileBytes {
		return Result{}, errors.New("invalid audio size")
	}
	ctx, cancel := context.WithTimeout(ctx, 110*time.Minute)
	defer cancel()
	audio, err := w.objects.Open(ctx, j.Key)
	if err != nil {
		return Result{}, err
	}
	defer audio.Close()
	req, err := http.NewRequestWithContext(ctx, "POST", w.endpoint+"/transcribe", io.LimitReader(audio, j.Size))
	if err != nil {
		return Result{}, err
	}
	req.ContentLength = j.Size
	req.Header.Set("Authorization", "Bearer "+w.token)
	req.Header.Set("Content-Type", "application/octet-stream")
	resp, err := w.client.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("transcription HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxTranscriptResponseBytes+1))
	if err != nil {
		return Result{}, err
	}
	if len(body) > maxTranscriptResponseBytes {
		return Result{}, errors.New("transcript too large")
	}
	var r Result
	if err = json.Unmarshal(body, &r); err != nil {
		return Result{}, err
	}
	if strings.TrimSpace(r.Plain) == "" || len(r.Plain) > MaxPlainTextBytes || len(r.Synced) > MaxTimedTextBytes {
		return Result{}, errors.New("invalid transcript")
	}
	r.State = "done"
	return r, nil
}
