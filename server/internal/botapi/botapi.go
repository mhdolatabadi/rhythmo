// Package botapi talks to Telegram-style Bot APIs. Bale's Bot API follows
// Telegram's methods and update format, so one client serves both; each
// messenger differs only in its Config.
package botapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
)

type Config struct {
	// Name is the provider name rhythmo uses, for example "bale".
	Name string
	// BaseURL is the API origin, for example https://tapi.bale.ai. Methods
	// are called at {BaseURL}/bot{token}/{method} and files are downloaded
	// from {BaseURL}/file/bot{token}/{file_path}.
	BaseURL string
	Token   string
	// MaxDownloadBytes is the largest file the API lets bots download.
	MaxDownloadBytes int64
	// MaxUploadBytes is the largest file the API lets bots upload.
	MaxUploadBytes int64
	// ProxyURL, if set, routes every request to the API through an HTTP(S)
	// or SOCKS5 proxy, for servers that cannot reach the API directly.
	ProxyURL string
	// SecretToken, if set, is registered with the webhook; Telegram then
	// sends it in the X-Telegram-Bot-Api-Secret-Token header of every update.
	SecretToken string
}

// SecretTokenHeader carries Config.SecretToken on webhook requests.
const SecretTokenHeader = "X-Telegram-Bot-Api-Secret-Token"

type Client struct {
	config Config
	http   *http.Client
	// files downloads without the overall timeout, since audio can be large.
	files *http.Client
}

func New(config Config) (*Client, error) {
	if config.Name == "" || config.BaseURL == "" || config.Token == "" || config.MaxDownloadBytes <= 0 {
		return nil, errors.New("bot API name, base URL, token and download limit are required")
	}
	if config.MaxUploadBytes <= 0 {
		config.MaxUploadBytes = defaultMaxUploadBytes
	}
	config.BaseURL = strings.TrimSuffix(config.BaseURL, "/")
	proxy := http.ProxyFromEnvironment
	if config.ProxyURL != "" {
		proxyURL, err := url.Parse(config.ProxyURL)
		if err != nil || proxyURL.Host == "" {
			return nil, fmt.Errorf("proxy URL %q is not a URL", config.ProxyURL)
		}
		proxy = http.ProxyURL(proxyURL)
	}
	return &Client{
		config: config,
		http: &http.Client{
			Timeout:   30 * time.Second,
			Transport: &http.Transport{Proxy: proxy, TLSHandshakeTimeout: 15 * time.Second},
		},
		files: &http.Client{Transport: &http.Transport{
			Proxy: proxy, TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: time.Minute,
		}},
	}, nil
}

// defaultMaxUploadBytes is Telegram's limit for files bots upload.
const defaultMaxUploadBytes = 50 << 20

func (c *Client) Name() string            { return c.config.Name }
func (c *Client) MaxDownloadBytes() int64 { return c.config.MaxDownloadBytes }
func (c *Client) MaxUploadBytes() int64   { return c.config.MaxUploadBytes }

type apiResponse struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	Description string          `json:"description"`
	ErrorCode   int             `json:"error_code"`
}

// call posts a method. Errors never include the token, which is part of the URL.
func (c *Client) call(ctx context.Context, method string, params, result any) error {
	body, err := json.Marshal(params)
	if err != nil {
		return err
	}
	return c.post(ctx, c.http, method, bytes.NewReader(body), "application/json", result)
}

func (c *Client) post(ctx context.Context, client *http.Client, method string, body io.Reader, contentType string, result any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.config.BaseURL+"/bot"+c.config.Token+"/"+method, body)
	if err != nil {
		return c.redact(method, err)
	}
	request.Header.Set("Content-Type", contentType)
	response, err := client.Do(request)
	if err != nil {
		return c.redact(method, err)
	}
	defer response.Body.Close()
	var decoded apiResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&decoded); err != nil {
		return fmt.Errorf("%s %s: HTTP %d: %w", c.config.Name, method, response.StatusCode, err)
	}
	if !decoded.OK {
		if decoded.ErrorCode == 0 {
			decoded.ErrorCode = response.StatusCode
		}
		return &APIError{Method: method, Code: decoded.ErrorCode, Description: decoded.Description}
	}
	if result == nil {
		return nil
	}
	return json.Unmarshal(decoded.Result, result)
}

// APIError is a request the API refused.
type APIError struct {
	Method      string
	Code        int
	Description string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("%s: %d %s", e.Method, e.Code, e.Description)
}

func (c *Client) redact(method string, err error) error {
	return fmt.Errorf("%s %s: %s", c.config.Name, method, strings.ReplaceAll(err.Error(), c.config.Token, "<token>"))
}

func (c *Client) Send(ctx context.Context, chatID, text string) error {
	return c.call(ctx, "sendMessage", map[string]any{"chat_id": json.Number(chatID), "text": text}, nil)
}

// SetWebhook points the API at url for new messages and channel posts.
func (c *Client) SetWebhook(ctx context.Context, url string) error {
	params := map[string]any{"url": url, "allowed_updates": []string{"message", "channel_post"}}
	if c.config.SecretToken != "" {
		params["secret_token"] = c.config.SecretToken
	}
	return c.call(ctx, "setWebhook", params, nil)
}

type webhookInfo struct {
	URL                  string `json:"url"`
	PendingUpdateCount   int    `json:"pending_update_count"`
	LastErrorDate        int64  `json:"last_error_date"`
	LastErrorMessage     string `json:"last_error_message"`
	MaxConnections       int    `json:"max_connections"`
	LastSyncErrorDate    int64  `json:"last_synchronization_error_date"`
	HasCustomCertificate bool   `json:"has_custom_certificate"`
}

// WebhookInfo reports what the provider knows about the webhook. The URL
// itself holds the webhook secret, so only whether it matches is returned.
func (c *Client) WebhookInfo(ctx context.Context, expectedURL string) (bot.WebhookStatus, error) {
	var info webhookInfo
	if err := c.call(ctx, "getWebhookInfo", map[string]any{}, &info); err != nil {
		return bot.WebhookStatus{}, err
	}
	status := bot.WebhookStatus{
		Registered:       info.URL != "",
		MatchesExpected:  info.URL == expectedURL,
		PendingUpdates:   info.PendingUpdateCount,
		LastErrorMessage: info.LastErrorMessage,
	}
	if info.LastErrorDate > 0 {
		at := time.Unix(info.LastErrorDate, 0).UTC()
		status.LastErrorAt = &at
	}
	return status, nil
}

type sentMessage struct {
	Audio    *document `json:"audio"`
	Document *document `json:"document"`
}

// SendAudio posts audio to a chat: by file ID when the API already has it,
// otherwise by streaming Body as a multipart upload.
func (c *Client) SendAudio(ctx context.Context, chatID string, audio bot.OutgoingAudio) (string, error) {
	var sent sentMessage
	var err error
	if audio.FileID != "" {
		params := map[string]any{"chat_id": json.Number(chatID), "audio": audio.FileID}
		if audio.Title != "" {
			params["title"] = audio.Title
		}
		if audio.Performer != "" {
			params["performer"] = audio.Performer
		}
		err = c.call(ctx, "sendAudio", params, &sent)
	} else {
		if audio.Size > c.config.MaxUploadBytes {
			return "", bot.ErrFileTooLarge
		}
		err = c.upload(ctx, chatID, audio, &sent)
	}
	var apiErr *APIError
	if errors.As(err, &apiErr) && (apiErr.Code == http.StatusRequestEntityTooLarge ||
		strings.Contains(strings.ToLower(apiErr.Description), "too large") ||
		strings.Contains(strings.ToLower(apiErr.Description), "too big")) {
		return "", bot.ErrFileTooLarge
	}
	if err != nil {
		return "", err
	}
	for _, f := range []*document{sent.Audio, sent.Document} {
		if f != nil && f.FileID != "" {
			return f.FileID, nil
		}
	}
	return "", nil
}

// upload streams the audio as multipart/form-data without buffering it.
func (c *Client) upload(ctx context.Context, chatID string, audio bot.OutgoingAudio, result any) error {
	reader, writer := io.Pipe()
	form := multipart.NewWriter(writer)
	go func() {
		err := func() error {
			fields := map[string]string{"chat_id": chatID, "title": audio.Title, "performer": audio.Performer}
			for _, name := range []string{"chat_id", "title", "performer"} {
				if fields[name] == "" {
					continue
				}
				if err := form.WriteField(name, fields[name]); err != nil {
					return err
				}
			}
			part, err := form.CreateFormFile("audio", audio.FileName)
			if err != nil {
				return err
			}
			n, err := io.Copy(part, io.LimitReader(audio.Body, audio.Size+1))
			if err != nil {
				return err
			}
			if n != audio.Size {
				return fmt.Errorf("audio has %d bytes, expected %d", n, audio.Size)
			}
			return form.Close()
		}()
		writer.CloseWithError(err)
	}()
	err := c.post(ctx, c.files, "sendAudio", reader, form.FormDataContentType(), result)
	reader.Close()
	return err
}

type fileInfo struct {
	FilePath string `json:"file_path"`
	FileSize int64  `json:"file_size"`
}

// Open resolves a file ID and streams its content.
func (c *Client) Open(ctx context.Context, fileID string) (io.ReadCloser, int64, error) {
	var info fileInfo
	if err := c.call(ctx, "getFile", map[string]any{"file_id": fileID}, &info); err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) && strings.Contains(strings.ToLower(apiErr.Description), "too big") {
			return nil, 0, bot.ErrFileTooLarge
		}
		return nil, 0, err
	}
	if info.FilePath == "" {
		return nil, 0, fmt.Errorf("%s getFile: no file path", c.config.Name)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.config.BaseURL+"/file/bot"+c.config.Token+"/"+strings.TrimPrefix(info.FilePath, "/"), nil)
	if err != nil {
		return nil, 0, c.redact("download", err)
	}
	response, err := c.files.Do(request)
	if err != nil {
		return nil, 0, c.redact("download", err)
	}
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		return nil, 0, fmt.Errorf("%s download: HTTP %d", c.config.Name, response.StatusCode)
	}
	// Bale's getFile can report a file_size unrelated to the file (85 for a
	// 17 MB audio), so the size of the download itself wins when it is known.
	size := response.ContentLength
	if size < 0 {
		size = info.FileSize
	}
	return response.Body, size, nil
}

type update struct {
	UpdateID json.Number `json:"update_id"`
	Message  *message    `json:"message"`
	// ChannelPost is a post in a channel the bot administers (#430).
	ChannelPost *message `json:"channel_post"`
}

type message struct {
	MessageID json.Number `json:"message_id"`
	Chat      struct {
		ID    json.Number `json:"id"`
		Type  string      `json:"type"`
		Title string      `json:"title"`
	} `json:"chat"`
	Text     string    `json:"text"`
	Audio    *document `json:"audio"`
	Document *document `json:"document"`
}

type document struct {
	FileID    string `json:"file_id"`
	FileName  string `json:"file_name"`
	MIMEType  string `json:"mime_type"`
	FileSize  int64  `json:"file_size"`
	Title     string `json:"title"`
	Performer string `json:"performer"`
}

// Parse reads a webhook body. New messages and new channel posts are
// handled; edits and other update kinds are acknowledged and ignored.
func Parse(body []byte) (bot.Update, bool, error) {
	var u update
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&u); err != nil {
		return bot.Update{}, false, err
	}
	if u.UpdateID == "" {
		return bot.Update{}, false, errors.New("update without update_id")
	}
	m := u.Message
	if m == nil {
		m = u.ChannelPost
	}
	if m == nil {
		return bot.Update{}, false, nil
	}
	parsed := bot.Update{
		ID:        u.UpdateID.String(),
		ChatID:    m.Chat.ID.String(),
		Private:   m.Chat.Type == "private",
		Channel:   u.Message == nil && m.Chat.Type == "channel",
		ChatTitle: m.Chat.Title,
		MessageID: m.MessageID.String(),
		Text:      m.Text,
	}
	file := m.Audio
	if file == nil {
		file = m.Document
	}
	if file != nil && file.FileID != "" {
		parsed.File = &bot.File{
			ID: file.FileID, Name: file.FileName, MIMEType: file.MIMEType, SizeBytes: file.FileSize,
			Title: file.Title, Performer: file.Performer,
		}
	}
	return parsed, true, nil
}
