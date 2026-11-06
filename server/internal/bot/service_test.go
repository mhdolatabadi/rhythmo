package bot

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

var song = append([]byte("ID3\x04\x00\x00\x00\x00\x00\x00"), make([]byte, 90)...)

type harness struct {
	t        *testing.T
	store    *memStore
	users    fakeUsers
	provider *fakeProvider
	tracks   *fakeTracks
	objects  *fakeObjects
	linker   *Linker
	importer *Importer
	service  *Service
	update   int
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{
		t:        t,
		store:    newMemStore(),
		users:    fakeUsers{"u1": {ID: "u1", Email: "listener@example.com"}},
		provider: &fakeProvider{files: map[string][]byte{"song": song}, maxBytes: 20 << 20},
		tracks:   &fakeTracks{tracks: map[string]store.Track{}},
		objects:  &fakeObjects{objects: map[string][]byte{}},
	}
	linker, err := NewLinker(h.store, make([]byte, 32), DefaultLinkLimits)
	if err != nil {
		t.Fatal(err)
	}
	linker.now = func() time.Time { return clock }
	h.linker = linker
	h.importer = NewImporter(h.store, h.tracks, h.objects, UploadPolicy{
		Enabled: true, MaxFileBytes: 200 << 20, MaxOwnerBytes: 5 << 30, MaxPending: 3,
	})
	h.importer.retryDelay = 0
	h.service = NewService(h.provider, h.store, linker, h.users, h.importer)
	h.service.imports = func(work func()) { work() }
	return h
}

func (h *harness) send(u Update) string {
	h.t.Helper()
	h.update++
	if u.ID == "" {
		u.ID = fmt.Sprint(h.update)
	}
	if u.ChatID == "" {
		u.ChatID = "42"
		u.Private = true
	}
	if u.MessageID == "" {
		u.MessageID = u.ID
	}
	if err := h.service.Handle(context.Background(), u); err != nil {
		h.t.Fatalf("Handle(%+v): %v", u, err)
	}
	return h.provider.last()
}

func (h *harness) text(text string) string {
	h.t.Helper()
	return h.send(Update{Text: text})
}

// code issues a link code from the app for the listener.
func (h *harness) code() string {
	h.t.Helper()
	code, _, err := h.linker.NewCode(context.Background(), "u1")
	if err != nil {
		h.t.Fatal(err)
	}
	return code
}

// signIn links the chat with a fresh code.
func (h *harness) signIn() {
	h.t.Helper()
	if reply := h.text(h.code()); reply != msgLinked("l***@example.com") {
		h.t.Fatalf("link reply = %q", reply)
	}
}

func TestLinkWithAppCodeThenImportAudio(t *testing.T) {
	h := newHarness(t)

	if reply := h.text("/start"); reply != msgWelcome {
		t.Fatalf("/start = %q", reply)
	}
	if reply := h.send(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: 1}}); reply != msgNotLinked {
		t.Fatalf("file before linking = %q", reply)
	}
	if reply := h.text("12345678"); reply != msgBadCode {
		t.Fatalf("made-up code = %q", reply)
	}

	// Typed on a Persian keyboard, with the space the app shows.
	code := h.code()
	persian := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r - '0' + '۰'
		}
		return r
	}, code[:4]+" "+code[4:])
	if reply := h.text(persian); reply != msgLinked("l***@example.com") {
		t.Fatalf("right code reply = %q", reply)
	}
	if reply := h.text(code); reply != msgBadCode {
		t.Fatalf("used code = %q", reply)
	}
	if reply := h.text("/status"); reply != msgStatus("l***@example.com") {
		t.Fatalf("/status = %q", reply)
	}

	h.send(Update{File: &File{ID: "song", Name: "My Song.mp3", SizeBytes: int64(len(song)), Title: "آهنگ من", Performer: "خواننده"}})
	if last := h.provider.last(); last != msgImported("آهنگ من") {
		t.Fatalf("import reply = %q (all: %q)", last, h.provider.messages)
	}
	if len(h.tracks.tracks) != 1 {
		t.Fatalf("tracks = %+v", h.tracks.tracks)
	}
	for _, track := range h.tracks.tracks {
		if track.OwnerID != "u1" || track.Status != store.TrackReady || *track.Artist != "خواننده" || track.Source != "bale" {
			t.Fatalf("track = %+v", track)
		}
		if string(h.objects.objects[track.StorageKey]) != string(song) {
			t.Fatal("stored object differs from the download")
		}
	}

	m := h.service.Metrics().Snapshot()
	if m.Links != 1 || m.LinkFailures != 2 || m.ImportsDone != 1 || m.Updates < 5 {
		t.Fatalf("metrics = %+v", m)
	}

	if reply := h.text("/logout"); reply != msgUnlinked {
		t.Fatalf("/logout = %q", reply)
	}
	if reply := h.send(Update{File: &File{ID: "song", Name: "b.mp3", SizeBytes: 1}}); reply != msgNotLinked {
		t.Fatalf("file after logout = %q", reply)
	}
}

func TestDeepLinkStartCarriesTheCode(t *testing.T) {
	h := newHarness(t)
	if reply := h.text("/start " + h.code()); reply != msgLinked("l***@example.com") {
		t.Fatalf("/start <code> = %q", reply)
	}
}

func TestExpiredCodeIsRefused(t *testing.T) {
	h := newHarness(t)
	code := h.code()
	clock = clock.Add(DefaultLinkLimits.CodeTTL + time.Second)
	if reply := h.text(code); reply != msgBadCode {
		t.Fatalf("expired code = %q", reply)
	}
}

func TestWrongCodesLockTheChatOut(t *testing.T) {
	h := newHarness(t)
	code := h.code()
	wrong := "00000000"
	if code == wrong {
		wrong = "11111111"
	}
	for i := 0; i < DefaultLinkLimits.MaxFailures-1; i++ {
		h.text(wrong)
	}
	if reply := h.text(wrong); reply != msgLocked {
		t.Fatalf("last allowed wrong code = %q", reply)
	}
	if reply := h.text(code); reply != msgLocked {
		t.Fatalf("right code while locked out = %q", reply)
	}
	clock = clock.Add(DefaultLinkLimits.FailureWindow)
	if reply := h.text(h.code()); reply != msgLinked("l***@example.com") {
		t.Fatalf("right code after the window = %q", reply)
	}
}

func TestANewCodeReplacesTheOldOne(t *testing.T) {
	h := newHarness(t)
	old := h.code()
	fresh := h.code()
	if old != fresh {
		if reply := h.text(old); reply != msgBadCode {
			t.Fatalf("replaced code = %q", reply)
		}
	}
	if reply := h.text(fresh); reply != msgLinked("l***@example.com") {
		t.Fatalf("fresh code = %q", reply)
	}
}

func TestExpiredSessionUnlinks(t *testing.T) {
	h := newHarness(t)
	h.signIn()
	clock = clock.Add(DefaultLinkLimits.SessionTTL + time.Hour)
	if reply := h.text("/status"); reply != msgNotLinked {
		t.Fatalf("/status after session expiry = %q", reply)
	}
}

func TestRedeliveredUpdatesAndMessagesImportOnce(t *testing.T) {
	h := newHarness(t)
	h.signIn()
	file := &File{ID: "song", Name: "a.mp3", SizeBytes: int64(len(song))}

	h.send(Update{ID: "900", MessageID: "7", File: file})
	sent := len(h.provider.messages)
	h.send(Update{ID: "900", MessageID: "7", File: file})
	// A new update ID for the same message, as after a provider-side retry.
	h.send(Update{ID: "901", MessageID: "7", File: file})

	if len(h.provider.messages) != sent {
		t.Fatalf("duplicates were answered: %q", h.provider.messages[sent:])
	}
	if len(h.tracks.tracks) != 1 {
		t.Fatalf("imported %d tracks", len(h.tracks.tracks))
	}
	if d := h.service.Metrics().Duplicates.Load(); d != 1 {
		t.Fatalf("duplicates counted = %d", d)
	}
}

func TestRefusedFilesExplainWhy(t *testing.T) {
	h := newHarness(t)
	h.signIn()

	cases := []struct {
		name string
		file *File
		want string
	}{
		{"pdf", &File{ID: "doc", Name: "notes.pdf", MIMEType: "application/pdf", SizeBytes: 10}, ReasonUnsupported},
		{"over provider limit", &File{ID: "song", Name: "big.mp3", SizeBytes: 21 << 20}, ReasonTooLarge},
		{"not really mp3", &File{ID: "fake", Name: "fake.mp3", SizeBytes: 20}, ReasonInvalid},
	}
	h.provider.files["fake"] = []byte("<html>not audio</html>")
	for _, c := range cases {
		if reply := h.send(Update{File: c.file}); reply != h.service.refused(c.want) {
			t.Errorf("%s: reply = %q", c.name, reply)
		}
	}
	if len(h.tracks.tracks) != 0 || len(h.objects.objects) != 0 {
		t.Fatalf("refused files left tracks %v or objects %v", h.tracks.tracks, h.objects.objects)
	}

	h.tracks.quotaErr = store.ErrQuotaExceeded
	if reply := h.send(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: 1}}); reply != h.service.refused(ReasonQuota) {
		t.Fatalf("quota reply = %q", reply)
	}
}

func TestAudioWithoutAFileNameUsesItsMIMEType(t *testing.T) {
	h := newHarness(t)
	h.signIn()
	h.send(Update{File: &File{ID: "song", MIMEType: "audio/mpeg", SizeBytes: int64(len(song))}})
	if last := h.provider.last(); last != msgImported("track") {
		t.Fatalf("reply = %q", last)
	}
}

func TestStorageFailuresAreRetriedThenCleanedUp(t *testing.T) {
	h := newHarness(t)
	h.signIn()
	h.objects.putErr = errors.New("minio down")

	h.send(Update{File: &File{ID: "song", Name: "a.mp3", SizeBytes: int64(len(song))}})

	if last := h.provider.last(); last != h.service.refused(ReasonFailed) {
		t.Fatalf("reply = %q", last)
	}
	if len(h.tracks.tracks) != 0 {
		t.Fatalf("failed import left a reservation: %v", h.tracks.tracks)
	}
	for _, job := range h.store.imports {
		if job.Attempts != h.importer.maxAttempts || job.State != store.ImportFailed {
			t.Fatalf("import = %+v", job)
		}
	}
}

func TestGroupChatsAreRefused(t *testing.T) {
	h := newHarness(t)
	if reply := h.send(Update{ChatID: "-100", Text: "/start"}); reply != msgPrivateOnly {
		t.Fatalf("group /start = %q", reply)
	}
	h.send(Update{ChatID: "-100", Text: "hello everyone"})
	if len(h.provider.messages) != 1 {
		t.Fatalf("replied to group chatter: %q", h.provider.messages)
	}
}

func TestResumeFinishesInterruptedImports(t *testing.T) {
	h := newHarness(t)
	h.signIn()
	job, err := h.importer.Queue(context.Background(), h.provider,
		Update{ChatID: "42", MessageID: "5", File: &File{ID: "song", Name: "a.mp3"}}, "u1", nil)
	if err != nil {
		t.Fatal(err)
	}
	// It was mid-download when the process stopped.
	h.store.imports[job.ID].State = store.ImportDownloading
	h.importer.now = func() time.Time { return clock.Add(time.Second) }

	h.service.Resume(context.Background())
	if h.store.imports[job.ID].State != store.ImportDone {
		t.Fatalf("resumed import = %+v", h.store.imports[job.ID])
	}
}

func TestParseCommand(t *testing.T) {
	for text, want := range map[string][2]string{
		"/start": {"start", ""}, "/Start@NafirBot": {"start", ""},
		"/start 1234 5678": {"start", "1234 5678"}, "/": {"", ""},
	} {
		command, argument, ok := parseCommand(text)
		if command != want[0] || argument != want[1] || ok != (want[0] != "") {
			t.Errorf("parseCommand(%q) = %q, %q, %v", text, command, argument, ok)
		}
	}
	if _, _, ok := parseCommand("hello"); ok {
		t.Error("plain text parsed as a command")
	}
}

func TestNormalizeCode(t *testing.T) {
	for input, want := range map[string]string{
		"12345678": "12345678", "۱۲۳۴ ۵۶۷۸": "12345678", "١٢٣٤-٥٦٧٨": "12345678", "1234567": "", "1234a678": "",
	} {
		got, ok := NormalizeCode(input)
		if ok != (want != "") || (ok && got != want) {
			t.Errorf("normalizeCode(%q) = %q, %v", input, got, ok)
		}
	}
}
