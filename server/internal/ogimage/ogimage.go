// Package ogimage draws the 1200×630 cards link previews show for a public
// playlist or store song: its name and artist in Vazirmatn, right to left,
// next to the rhythmo icon.
package ogimage

import (
	"bytes"
	"embed"
	"image"
	"image/color"
	"image/draw"
	"image/jpeg"
	"image/png"
	"math"
	"sync"

	"github.com/go-text/typesetting/di"
	"github.com/go-text/typesetting/font"
	ot "github.com/go-text/typesetting/font/opentype"
	"github.com/go-text/typesetting/language"
	"github.com/go-text/typesetting/shaping"
	xdraw "golang.org/x/image/draw"
	"golang.org/x/image/math/fixed"
	"golang.org/x/image/vector"
)

// Width and Height are the card's size, the one Open Graph and Telegram
// previews expect.
const (
	Width  = 1200
	Height = 630
)

//go:embed fonts/Vazirmatn-Bold.ttf fonts/Vazirmatn-Regular.ttf rhythmo.png
var files embed.FS

// Card is what one preview says. Kicker names the kind of page, such as
// «آهنگ»; Footer is usually the site's host.
type Card struct {
	Kicker   string
	Title    string
	Subtitle string
	Footer   string
}

var (
	loadOnce          sync.Once
	boldFont, regFont *font.Font
	icon              image.Image
	// backdrop is the background and icon every card shares.
	backdrop *image.RGBA
	loadErr  error
)

func load() error {
	loadOnce.Do(func() {
		parse := func(name string) *font.Font {
			data, err := files.ReadFile(name)
			if err != nil {
				loadErr = err
				return nil
			}
			face, err := font.ParseTTF(bytes.NewReader(data))
			if err != nil {
				loadErr = err
				return nil
			}
			return face.Font
		}
		boldFont = parse("fonts/Vazirmatn-Bold.ttf")
		regFont = parse("fonts/Vazirmatn-Regular.ttf")
		data, err := files.ReadFile("rhythmo.png")
		if err == nil {
			icon, err = png.Decode(bytes.NewReader(data))
		}
		if err != nil && loadErr == nil {
			loadErr = err
		}
		if loadErr == nil {
			backdrop = drawBackdrop()
		}
	})
	return loadErr
}

// drawBackdrop paints the background and the rounded icon on the left.
func drawBackdrop() *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, Width, Height))
	paintBackground(img)
	const iconSize = 220
	iconRect := image.Rect(120, (Height-iconSize)/2, 120+iconSize, (Height+iconSize)/2)
	scaled := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	xdraw.CatmullRom.Scale(scaled, scaled.Bounds(), icon, icon.Bounds(), xdraw.Src, nil)
	draw.DrawMask(img, iconRect, scaled, image.Point{}, roundedMask(iconSize, 48), image.Point{}, draw.Over)
	return img
}

var (
	background = color.RGBA{0x07, 0x08, 0x10, 0xff}
	textColor  = color.RGBA{0xf3, 0xf4, 0xf8, 0xff}
	mutedColor = color.RGBA{0xb4, 0xb8, 0xc7, 0xff}
	primary    = color.RGBA{0xff, 0x62, 0x6a, 0xff}
)

const (
	// textRight is where the right-aligned text ends; textLeft leaves room
	// for the icon.
	textRight = Width - 96
	textLeft  = 400
)

// Render draws the card as a JPEG, which encodes the gradient quickly and
// small.
func Render(card Card) ([]byte, error) {
	if err := load(); err != nil {
		return nil, err
	}
	img := image.NewRGBA(backdrop.Bounds())
	copy(img.Pix, backdrop.Pix)

	shaper := &shaping.HarfbuzzShaper{}
	type block struct {
		text     string
		font     *font.Font
		size     float64
		color    color.Color
		maxLines int
		gap      float64
	}
	blocks := []block{
		{card.Kicker, boldFont, 34, primary, 1, 18},
		{card.Title, boldFont, 72, textColor, 2, 20},
		{card.Subtitle, regFont, 38, mutedColor, 2, 28},
		{card.Footer, regFont, 30, primary, 1, 0},
	}
	var laid [][]shaping.Line
	total := 0.0
	for _, b := range blocks {
		if b.text == "" {
			laid = append(laid, nil)
			continue
		}
		lines := wrap(shaper, b.text, b.font, b.size, b.maxLines)
		laid = append(laid, lines)
		total += float64(len(lines))*b.size*1.45 + b.gap
	}
	y := (Height - total) / 2
	for i, b := range blocks {
		for _, line := range laid[i] {
			y += b.size * 1.45
			drawLine(img, line, float64(textRight), y-b.size*0.4, b.color)
		}
		if laid[i] != nil {
			y += b.gap
		}
	}
	var out bytes.Buffer
	if err := jpeg.Encode(&out, img, &jpeg.Options{Quality: 90}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// paintBackground lays the brand's dark gradient with a warm glow at the
// top right and a cool one at the bottom left.
func paintBackground(img *image.RGBA) {
	glow := func(x, y, cx, cy, radius float64) float64 {
		d := math.Hypot(x-cx, y-cy) / radius
		return math.Max(0, 1-d) * math.Max(0, 1-d)
	}
	for y := 0; y < Height; y++ {
		for x := 0; x < Width; x++ {
			warm := glow(float64(x), float64(y), 1000, 80, 700) * 0.35
			cool := glow(float64(x), float64(y), 80, 620, 650) * 0.3
			r := float64(background.R) + warm*(0x5a-float64(background.R)) + cool*(0x1a-float64(background.R))
			g := float64(background.G) + warm*(0x1c-float64(background.G)) + cool*(0x22-float64(background.G))
			b := float64(background.B) + warm*(0x24-float64(background.B)) + cool*(0x55-float64(background.B))
			img.SetRGBA(x, y, color.RGBA{uint8(r), uint8(g), uint8(b), 0xff})
		}
	}
}

// roundedMask is a size×size square with rounded corners.
func roundedMask(size int, radius float64) *image.Alpha {
	var z vector.Rasterizer
	z.Reset(size, size)
	s, r := float32(size), float32(radius)
	const k = 0.5523
	z.MoveTo(r, 0)
	z.LineTo(s-r, 0)
	z.CubeTo(s-r+r*k, 0, s, r-r*k, s, r)
	z.LineTo(s, s-r)
	z.CubeTo(s, s-r+r*k, s-r+r*k, s, s-r, s)
	z.LineTo(r, s)
	z.CubeTo(r-r*k, s, 0, s-r+r*k, 0, s-r)
	z.LineTo(0, r)
	z.CubeTo(0, r-r*k, r-r*k, 0, r, 0)
	z.ClosePath()
	mask := image.NewAlpha(image.Rect(0, 0, size, size))
	z.Draw(mask, mask.Bounds(), image.Opaque, image.Point{})
	return mask
}

type singleFont struct{ face *font.Face }

func (f singleFont) ResolveFace(rune) *font.Face { return f.face }

// wrap shapes text right to left and breaks it into at most maxLines lines
// that fit beside the icon, ending a cut line with an ellipsis.
func wrap(shaper *shaping.HarfbuzzShaper, text string, f *font.Font, size float64, maxLines int) []shaping.Line {
	face := font.NewFace(f)
	runes := []rune(text)
	input := shaping.Input{
		Text: runes, RunEnd: len(runes), Direction: di.DirectionRTL, Face: face,
		Size: fixed.Int26_6(size * 64), Script: language.Arabic, Language: language.NewLanguage("fa"),
	}
	var segmenter shaping.Segmenter
	var outputs []shaping.Output
	for _, run := range segmenter.Split(input, singleFont{face}) {
		outputs = append(outputs, shaper.Shape(run))
	}
	ellipsis := []rune("…")
	truncator := shaper.Shape(shaping.Input{
		Text: ellipsis, RunEnd: len(ellipsis), Direction: di.DirectionRTL, Face: face,
		Size: input.Size, Script: language.Arabic, Language: input.Language,
	})
	config := shaping.WrapConfig{Direction: di.DirectionRTL, TruncateAfterLines: maxLines, Truncator: truncator}
	var wrapper shaping.LineWrapper
	lines, _ := wrapper.WrapParagraph(config, textRight-textLeft, runes, shaping.NewSliceIterator(outputs))
	return lines
}

// drawLine draws a line's runs in visual order, ending at right on the
// baseline y.
func drawLine(img *image.RGBA, line shaping.Line, right, y float64, c color.Color) {
	ordered := make([]shaping.Output, len(line))
	width := 0.0
	for _, run := range line {
		ordered[run.VisualIndex] = run
		width += fixedFloat(run.Advance)
	}
	var z vector.Rasterizer
	z.Reset(Width, Height)
	x := right - width
	for _, run := range ordered {
		scale := fixedFloat(run.Size) / float64(run.Face.Upem())
		for _, g := range run.Glyphs {
			outline, ok := run.Face.GlyphDataOutline(g.GlyphID)
			if ok {
				gx, gy := x+fixedFloat(g.XOffset), y-fixedFloat(g.YOffset)
				pt := func(p ot.SegmentPoint) (float32, float32) {
					return float32(gx + float64(p.X)*scale), float32(gy - float64(p.Y)*scale)
				}
				for _, seg := range outline.Segments {
					switch seg.Op {
					case ot.SegmentOpMoveTo:
						z.ClosePath()
						z.MoveTo(pt(seg.Args[0]))
					case ot.SegmentOpLineTo:
						z.LineTo(pt(seg.Args[0]))
					case ot.SegmentOpQuadTo:
						ax, ay := pt(seg.Args[0])
						bx, by := pt(seg.Args[1])
						z.QuadTo(ax, ay, bx, by)
					case ot.SegmentOpCubeTo:
						ax, ay := pt(seg.Args[0])
						bx, by := pt(seg.Args[1])
						cx, cy := pt(seg.Args[2])
						z.CubeTo(ax, ay, bx, by, cx, cy)
					}
				}
				z.ClosePath()
			}
			x += fixedFloat(g.Advance)
		}
	}
	z.Draw(img, img.Bounds(), image.NewUniform(c), image.Point{})
}

func fixedFloat(v fixed.Int26_6) float64 { return float64(v) / 64 }
