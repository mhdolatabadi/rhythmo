package audioinfo

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/mhdolatabadi/rhythmo/server/internal/store"
)

type fakeStore struct {
	jobs  []store.AudioInfoJob
	saved map[string]store.AudioInfo
	ms    map[string]*int32
}

func (f *fakeStore) PendingAudioInfo(context.Context, int) ([]store.AudioInfoJob, error) {
	var left []store.AudioInfoJob
	for _, j := range f.jobs {
		if _, done := f.saved[j.ID]; !done {
			left = append(left, j)
		}
	}
	return left, nil
}

func (f *fakeStore) SetAudioInfo(_ context.Context, id, _ string, info store.AudioInfo, ms *int32) error {
	f.saved[id], f.ms[id] = info, ms
	return nil
}

type fakeObjects struct {
	files map[string][]byte
	down  bool
}

func (f *fakeObjects) ReadRange(_ context.Context, key string, offset, size int64) ([]byte, error) {
	if f.down {
		return nil, errors.New("storage is down")
	}
	data := f.files[key]
	end := min(int64(len(data)), offset+size)
	return data[offset:end], nil
}

func TestScanner(t *testing.T) {
	flac, err := os.ReadFile("testdata/song.flac")
	if err != nil {
		t.Fatal(err)
	}
	junk := []byte("not audio at all, but long enough to look at")
	s := &fakeStore{
		jobs: []store.AudioInfoJob{
			{ID: "f", StorageKey: "k/f", FileName: "song.flac", SizeBytes: int64(len(flac))},
			{ID: "j", StorageKey: "k/j", FileName: "junk.mp3", SizeBytes: int64(len(junk))},
		},
		saved: map[string]store.AudioInfo{}, ms: map[string]*int32{},
	}
	objects := &fakeObjects{files: map[string][]byte{"k/f": flac, "k/j": junk}, down: true}
	scanner := NewScanner(s, objects, 0, 10)

	if n, err := scanner.ScanOnce(context.Background()); err != nil || n != 0 {
		t.Fatalf("with storage down: %d, %v; nothing may be settled", n, err)
	}
	objects.down = false
	if n, err := scanner.ScanOnce(context.Background()); err != nil || n != 2 {
		t.Fatalf("ScanOnce = %d, %v", n, err)
	}
	if got := s.saved["f"]; got.Codec == nil || *got.Codec != "FLAC" || *got.BitDepth != 16 || s.ms["f"] == nil || *s.ms["f"] != 2000 {
		t.Fatalf("flac = %+v, %v ms", got, s.ms["f"])
	}
	if got := s.saved["j"]; got.Codec != nil {
		t.Fatalf("junk = %+v; settled as unknown", got)
	}
}
