package ogimage

import (
	"bytes"
	"image/jpeg"
	"strings"
	"testing"
)

func TestRenderDrawsACardOfThePreviewSize(t *testing.T) {
	song, err := Render(Card{Kicker: "آهنگ", Title: "باران", Subtitle: "از AC/DC · آلبوم Seasons", Footer: "rhythmo.ir"})
	if err != nil {
		t.Fatal(err)
	}
	img, err := jpeg.Decode(bytes.NewReader(song))
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != Width || b.Dy() != Height {
		t.Fatalf("card is %v", b)
	}
	// The title is drawn: the area right of the icon has light pixels.
	light := 0
	for y := 0; y < Height; y++ {
		for x := 420; x < Width-80; x++ {
			if r, g, b, _ := img.At(x, y).RGBA(); r > 0xe000 && g > 0xe000 && b > 0xe000 {
				light++
			}
		}
	}
	if light < 500 {
		t.Fatalf("only %d light pixels; the title was not drawn", light)
	}
	other, err := Render(Card{Kicker: "آهنگ", Title: "برف", Footer: "rhythmo.ir"})
	if err != nil || bytes.Equal(song, other) {
		t.Fatalf("different songs drew the same card: %v", err)
	}
}

func TestRenderCopesWithEmptyAndLongText(t *testing.T) {
	for _, card := range []Card{
		{},
		{Title: strings.Repeat("آهنگی با نامی بسیار طولانی و Latin words mixed in ", 20), Subtitle: strings.Repeat("خواننده ", 50)},
		{Title: "‏‌", Subtitle: "🎵"},
	} {
		if _, err := Render(card); err != nil {
			t.Fatalf("Render(%q) = %v", card.Title, err)
		}
	}
}

func BenchmarkRender(b *testing.B) {
	for b.Loop() {
		if _, err := Render(Card{Kicker: "فهرست پخش", Title: "Road trip", Subtitle: "۲۴ آهنگ", Footer: "rhythmo.ir"}); err != nil {
			b.Fatal(err)
		}
	}
}
