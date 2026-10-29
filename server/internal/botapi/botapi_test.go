package botapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/bot"
)

const token = "123456:secret-token"

// A private-chat audio message in the Telegram/Bale update format.
const audioUpdate = `{
  "update_id": 5001,
  "message": {
    "message_id": 77,
    "from": {"id": 9007199254740993, "is_bot": false, "first_name": "علی"},
    "chat": {"id": 9007199254740993, "type": "private"},
    "date": 1759150000,
    "audio": {
      "file_id": "AgADBAAD", "file_unique_id": "u1", "duration": 215,
      "performer": "خواننده", "title": "آهنگ", "file_name": "song.mp3",
      "mime_type": "audio/mpeg", "file_size": 5242880
    }
  }
}`

func TestParseAudioMessage(t *testing.T) {
	u, ok, err := Parse([]byte(audioUpdate))
	if err != nil || !ok {
		t.Fatalf("Parse = %v, %v", ok, err)
	}
	// Chat IDs beyond float64 precision must survive intact.
	if u.ID != "5001" || u.ChatID != "9007199254740993" || !u.Private || u.MessageID != "77" {
		t.Fatalf("update = %+v", u)
	}
	want := bot.File{ID: "AgADBAAD", Name: "song.mp3", MIMEType: "audio/mpeg", SizeBytes: 5242880, Title: "آهنگ", Performer: "خواننده"}
	if u.File == nil || *u.File != want {
		t.Fatalf("file = %+v", u.File)
	}
}

func TestParseDocumentTextGroupAndOtherUpdates(t *testing.T) {
	u, ok, _ := Parse([]byte(`{"update_id":1,"message":{"message_id":2,"chat":{"id":3,"type":"private"},
		"document":{"file_id":"d","file_name":"a.flac","mime_type":"audio/flac","file_size":10}}}`))
	if !ok || u.File == nil || u.File.Name != "a.flac" {
		t.Fatalf("document = %+v", u)
	}
	u, ok, _ = Parse([]byte(`{"update_id":1,"message":{"message_id":2,"chat":{"id":-100,"type":"group"},"text":"/start"}}`))
	if !ok || u.Private || u.Text != "/start" || u.File != nil {
		t.Fatalf("group text = %+v", u)
	}
	u, ok, _ = Parse([]byte(`{"update_id":1,"channel_post":{"message_id":9,"chat":{"id":-1001,"type":"channel","title":"Golden"},
		"audio":{"file_id":"c","file_name":"b.mp3","mime_type":"audio/mpeg","file_size":10}}}`))
	if !ok || !u.Channel || u.Private || u.ChatID != "-1001" || u.ChatTitle != "Golden" || u.File == nil || u.File.ID != "c" {
		t.Fatalf("channel post = %+v", u)
	}
	if _, ok, err := Parse([]byte(`{"update_id":1,"edited_channel_post":{"message_id":2}}`)); ok || err != nil {
		t.Fatalf("edited channel post: ok=%v err=%v", ok, err)
	}
	if _, ok, err := Parse([]byte(`{"update_id":1,"edited_message":{"message_id":2}}`)); ok || err != nil {
		t.Fatalf("edited message: ok=%v err=%v", ok, err)
	}
	if _, _, err := Parse([]byte(`{"message":{}}`)); err == nil {
		t.Fatal("update without ID accepted")
	}
	if _, _, err := Parse([]byte(`not json`)); err == nil {
		t.Fatal("invalid JSON accepted")
	}
}

func newTestClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client, err := New(Config{Name: "bale", BaseURL: server.URL + "/", Token: token, MaxDownloadBytes: 20 << 20})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestSendMessageAndDownloadFile(t *testing.T) {
	var sent map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/bot" + token + "/sendMessage":
			json.NewDecoder(r.Body).Decode(&sent)
			io.WriteString(w, `{"ok":true,"result":{}}`)
		case "/bot" + token + "/getFile":
			io.WriteString(w, `{"ok":true,"result":{"file_id":"f","file_path":"music/f.mp3","file_size":5}}`)
		case "/file/bot" + token + "/music/f.mp3":
			io.WriteString(w, "ID3xy")
		default:
			http.NotFound(w, r)
		}
	})

	if err := client.Send(context.Background(), "9007199254740993", "سلام"); err != nil {
		t.Fatal(err)
	}
	if sent["text"] != "سلام" || sent["chat_id"] != 9007199254740993.0 {
		t.Fatalf("sent %v", sent)
	}

	body, size, err := client.Open(context.Background(), "f")
	if err != nil {
		t.Fatal(err)
	}
	defer body.Close()
	data, _ := io.ReadAll(body)
	if size != 5 || string(data) != "ID3xy" {
		t.Fatalf("download = %d %q", size, data)
	}
}

func TestDownloadSizeComesFromTheResponseNotGetFile(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/bot" + token + "/getFile":
			// Bale reported 85 here for a 17 MB file.
			io.WriteString(w, `{"ok":true,"result":{"file_id":"f","file_path":"music/f.mp3","file_size":85}}`)
		case "/file/bot" + token + "/music/f.mp3":
			w.Header().Set("Content-Length", "5")
			io.WriteString(w, "ID3xy")
		default:
			http.NotFound(w, r)
		}
	})

	body, size, err := client.Open(context.Background(), "f")
	if err != nil {
		t.Fatal(err)
	}
	defer body.Close()
	data, _ := io.ReadAll(body)
	if size != 5 || string(data) != "ID3xy" {
		t.Fatalf("download = %d %q", size, data)
	}
}

func TestErrorsNeverContainTheToken(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"ok":false,"error_code":400,"description":"Bad Request: file is too big"}`)
	})
	if _, _, err := client.Open(context.Background(), "f"); !errors.Is(err, bot.ErrFileTooLarge) {
		t.Fatalf("too big: %v", err)
	}

	client.config.BaseURL = "http://127.0.0.1:1"
	err := client.Send(context.Background(), "1", "x")
	if err == nil || strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("connection error leaks the token: %v", err)
	}
}

func TestSetWebhookRegistersTheSecretToken(t *testing.T) {
	var params map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewDecoder(r.Body).Decode(&params)
		io.WriteString(w, `{"ok":true,"result":true}`)
	})
	client.config.SecretToken = "hook-secret"

	if err := client.SetWebhook(context.Background(), "https://music.example.com/hook"); err != nil {
		t.Fatal(err)
	}
	if params["secret_token"] != "hook-secret" || params["url"] != "https://music.example.com/hook" {
		t.Fatalf("setWebhook params = %v", params)
	}
	// Channel posts are asked for so channels can sync (#430).
	if fmt.Sprint(params["allowed_updates"]) != "[message channel_post]" {
		t.Fatalf("allowed_updates = %v", params["allowed_updates"])
	}
}

func TestRequestsGoThroughTheConfiguredProxy(t *testing.T) {
	var proxied []string
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxied = append(proxied, r.URL.Host+r.URL.Path)
		io.WriteString(w, `{"ok":true,"result":true}`)
	}))
	t.Cleanup(proxy.Close)
	client, err := New(Config{
		Name: "telegram", BaseURL: "http://api.telegram.invalid", Token: token,
		MaxDownloadBytes: 1, ProxyURL: proxy.URL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Send(context.Background(), "1", "x"); err != nil {
		t.Fatal(err)
	}
	if len(proxied) != 1 || proxied[0] != "api.telegram.invalid/bot"+token+"/sendMessage" {
		t.Fatalf("proxied %v", proxied)
	}
	if _, err := New(Config{Name: "x", BaseURL: "http://a", Token: "t", MaxDownloadBytes: 1, ProxyURL: "::"}); err == nil {
		t.Fatal("bad proxy URL accepted")
	}
}

func TestSendAudioUploadsThenSendsByFileID(t *testing.T) {
	var fields map[string]string
	var fileName, fileBody string
	var byID map[string]any
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
			if err := r.ParseMultipartForm(1 << 20); err != nil {
				t.Error(err)
			}
			fields = map[string]string{}
			for k, v := range r.MultipartForm.Value {
				fields[k] = v[0]
			}
			file, header, _ := r.FormFile("audio")
			data, _ := io.ReadAll(file)
			fileName, fileBody = header.Filename, string(data)
			io.WriteString(w, `{"ok":true,"result":{"message_id":1,"audio":{"file_id":"AUD1"}}}`)
			return
		}
		json.NewDecoder(r.Body).Decode(&byID)
		io.WriteString(w, `{"ok":true,"result":{"message_id":2,"audio":{"file_id":"AUD1"}}}`)
	})

	id, err := client.SendAudio(context.Background(), "9007199254740993", bot.OutgoingAudio{
		FileName: "song.mp3", Body: strings.NewReader("ID3data"), Size: 7, Title: "آهنگ", Performer: "خواننده",
	})
	if err != nil || id != "AUD1" {
		t.Fatalf("upload = %q, %v", id, err)
	}
	if fields["chat_id"] != "9007199254740993" || fields["title"] != "آهنگ" || fields["performer"] != "خواننده" ||
		fileName != "song.mp3" || fileBody != "ID3data" {
		t.Fatalf("multipart = %v %q %q", fields, fileName, fileBody)
	}

	if id, err := client.SendAudio(context.Background(), "5", bot.OutgoingAudio{FileID: "AUD1", Title: "آهنگ"}); err != nil || id != "AUD1" {
		t.Fatalf("by file ID = %q, %v", id, err)
	}
	if byID["audio"] != "AUD1" || byID["title"] != "آهنگ" {
		t.Fatalf("by file ID params = %v", byID)
	}
}

func TestSendAudioRefusesOversizedUploads(t *testing.T) {
	calls := 0
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusRequestEntityTooLarge)
		io.WriteString(w, `{"ok":false,"error_code":413,"description":"Request Entity Too Large"}`)
	})
	client.config.MaxUploadBytes = 5
	if _, err := client.SendAudio(context.Background(), "1", bot.OutgoingAudio{
		FileName: "a.mp3", Body: strings.NewReader("123456"), Size: 6,
	}); !errors.Is(err, bot.ErrFileTooLarge) || calls != 0 {
		t.Fatalf("over the configured limit: %v after %d calls", err, calls)
	}
	client.config.MaxUploadBytes = 100
	if _, err := client.SendAudio(context.Background(), "1", bot.OutgoingAudio{
		FileName: "a.mp3", Body: strings.NewReader("123456"), Size: 6,
	}); !errors.Is(err, bot.ErrFileTooLarge) {
		t.Fatalf("provider 413: %v", err)
	}
}

func TestWebhookInfoNeverReturnsTheURL(t *testing.T) {
	client := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"ok":true,"result":{"url":"https://music.example.com/api/v1/bots/bale/webhook/s3cret",
			"pending_update_count":4,"last_error_date":1759150000,"last_error_message":"Connection timed out"}}`)
	})
	status, err := client.WebhookInfo(context.Background(), "https://music.example.com/api/v1/bots/bale/webhook/s3cret")
	if err != nil {
		t.Fatal(err)
	}
	if !status.Registered || !status.MatchesExpected || status.PendingUpdates != 4 ||
		status.LastErrorMessage != "Connection timed out" || status.LastErrorAt == nil {
		t.Fatalf("status = %+v", status)
	}
	encoded, _ := json.Marshal(status)
	if strings.Contains(string(encoded), "s3cret") {
		t.Fatalf("webhook secret leaked: %s", encoded)
	}
	if other, _ := client.WebhookInfo(context.Background(), "https://elsewhere.example.com/hook"); other.MatchesExpected {
		t.Fatal("a different URL was reported as matching")
	}
}
