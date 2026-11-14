package mail

import (
	"bufio"
	"context"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"strings"
	"testing"
	"time"
)

func TestVerificationEmailIsPersianRTLWithPlainText(t *testing.T) {
	message := VerificationCode("user@example.com", "042917", 15)
	from, _ := mail.ParseAddress("ریتمو <no-reply@rhythmo.example>")
	to, _ := mail.ParseAddress(message.To)
	raw, err := Build(from, to, message, time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := mail.ReadMessage(strings.NewReader(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	subject, err := new(mime.WordDecoder).DecodeHeader(parsed.Header.Get("Subject"))
	if err != nil || subject != "کد تأیید ایمیل ریتمو" {
		t.Fatalf("subject = %q, %v", subject, err)
	}
	mediaType, params, err := mime.ParseMediaType(parsed.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/alternative" {
		t.Fatalf("content type = %q, %v", mediaType, err)
	}
	reader := multipart.NewReader(parsed.Body, params["boundary"])
	var kinds []string
	bodies := map[string]string{}
	for {
		part, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(part) // multipart decodes quoted-printable
		kind, _, _ := mime.ParseMediaType(part.Header.Get("Content-Type"))
		kinds = append(kinds, kind)
		bodies[kind] = string(body)
	}
	if strings.Join(kinds, ",") != "text/plain,text/html" {
		t.Fatalf("parts = %v; plain text must come first", kinds)
	}
	for kind, body := range bodies {
		if !strings.Contains(body, "042917") || !strings.Contains(body, "۱۵ دقیقه") {
			t.Errorf("%s body lacks the code or its lifetime: %q", kind, body)
		}
	}
	if !strings.Contains(bodies["text/html"], `dir="rtl"`) || !strings.Contains(bodies["text/html"], `lang="fa"`) {
		t.Error("the HTML part is not marked Persian and right-to-left")
	}
}

// fakeSMTP accepts one message on a local port and returns what it saw.
func fakeSMTP(t *testing.T) (int, <-chan string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	received := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		in := bufio.NewReader(conn)
		reply := func(line string) { _, _ = conn.Write([]byte(line + "\r\n")) }
		reply("220 localhost ESMTP")
		var transcript strings.Builder
		for {
			line, err := in.ReadString('\n')
			if err != nil {
				return
			}
			transcript.WriteString(line)
			command := strings.ToUpper(strings.TrimSpace(line))
			switch {
			case strings.HasPrefix(command, "EHLO"):
				reply("250-localhost")
				reply("250 AUTH PLAIN")
			case strings.HasPrefix(command, "AUTH"):
				reply("235 ok")
			case strings.HasPrefix(command, "DATA"):
				reply("354 go on")
				for {
					data, err := in.ReadString('\n')
					if err != nil {
						return
					}
					if data == ".\r\n" {
						break
					}
					transcript.WriteString(data)
				}
				reply("250 queued")
			case strings.HasPrefix(command, "QUIT"):
				reply("221 bye")
				received <- transcript.String()
				return
			default:
				reply("250 ok")
			}
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, received
}

func TestSMTPSendsTheMessage(t *testing.T) {
	port, received := fakeSMTP(t)
	sender, err := NewSMTP(Config{
		Host: "localhost", Port: port, Username: "relay", Password: "secret",
		From: "no-reply@rhythmo.example",
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := sender.Send(ctx, VerificationCode("user@example.com", "123456", 15)); err != nil {
		t.Fatal(err)
	}
	transcript := <-received
	for _, want := range []string{"AUTH PLAIN", "MAIL FROM:<no-reply@rhythmo.example>", "RCPT TO:<user@example.com>", "multipart/alternative"} {
		if !strings.Contains(transcript, want) {
			t.Errorf("transcript lacks %q", want)
		}
	}
}

func TestSMTPConfigIsChecked(t *testing.T) {
	for name, config := range map[string]Config{
		"no host":      {Port: 587, From: "a@b.c"},
		"bad port":     {Host: "smtp.example.com", Port: 0, From: "a@b.c"},
		"bad sender":   {Host: "smtp.example.com", Port: 587, From: "not an address"},
		"half a login": {Host: "smtp.example.com", Port: 587, From: "a@b.c", Username: "u"},
	} {
		if _, err := NewSMTP(config); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := NewSMTP(Config{Host: "smtp.example.com", Port: 587, From: "ریتمو <a@b.c>"}); err != nil {
		t.Fatalf("a named sender was refused: %v", err)
	}
}

func TestAccountEmailsCarryTheirCodeAndNoticeHasNone(t *testing.T) {
	for _, message := range []Message{
		SignupCode("a@example.com", "123456", 15),
		PasswordResetCode("a@example.com", "123456", 15),
	} {
		for _, body := range []string{message.Text, message.HTML} {
			if !strings.Contains(body, "123456") || !strings.Contains(body, "۱۵ دقیقه") {
				t.Errorf("%q lacks the code or its lifetime", message.Subject)
			}
		}
	}
	notice := SignupAttempt("a@example.com")
	if notice.To != "a@example.com" || !strings.Contains(notice.Text, "از قبل حساب دارد") ||
		!strings.Contains(notice.HTML, `dir="rtl"`) || strings.ContainsAny(notice.Text, "0123456789") {
		t.Fatalf("notice = %+v", notice)
	}
}
