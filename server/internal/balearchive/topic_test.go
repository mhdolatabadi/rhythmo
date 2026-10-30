package balearchive

import (
	"github.com/mhdolatabadi/rhythmo/server/internal/linkimport"
	"testing"
)

func message(caption, mime string) linkimport.BaleMessage {
	var m linkimport.BaleMessage
	m.RID = "123"
	m.Date = 1792673112764
	m.Message.Document = &linkimport.BaleDocument{URL: "https://file-gw6.ble.ir/proxy_download/token?u=x", Name: "lecture.mp3", FileSize: 100, MIMEType: mime}
	m.Message.Document.Caption.Text = caption
	return m
}
func TestOnlyMarkedFullAudio(t *testing.T) {
	for _, tc := range []struct {
		caption, mime string
		want          bool
	}{
		{"🎙 #سخنرانی_کامل\n📋 فاطمیه دقیقاً چیست؟ - جلسه اول", "audio/mpeg", true},
		{"🎙️ #سخنرانی_کامل", "audio/mpeg", true},
		{"🎙 #کلیپ", "audio/mpeg", false}, {"#سخنرانی_کامل", "audio/mpeg", false},
		{"🎙 #سخنرانی_کامل", "video/mp4", false},
	} {
		if got := FullLecture(message(tc.caption, tc.mime)); got != tc.want {
			t.Errorf("%q %s got %v", tc.caption, tc.mime, got)
		}
	}
	if FullLecture(linkimport.BaleMessage{}) {
		t.Fatal("text/quoted media must not qualify")
	}
}
func TestDifferentTopicsAndSessionNormalization(t *testing.T) {
	for _, tc := range []struct {
		caption, topic string
		session        int
	}{
		{"🎙 #سخنرانی_کامل\n📋 *ما و حضرت ولی‌عصر عجل الله تعالی فرجه الشریف؛ جلسه سیزدهم*\n🗓 سه‌شنبه", "ما و حضرت ولی عصر عجل الله تعالی فرجه الشریف", 13},
		{"📋 *فاطمیه دقیقاً چیست؟ - جلسه اول*", "فاطمیه دقیقا چیست؟", 1},
		{"📋 فاطميه دقيقاً چيست؟؛ جلسه ۲۱", "فاطمیه دقیقا چیست؟", 21},
		{"📋 موضوع؛ جلسه بیست‌ویکم", "موضوع", 21},
		{"📋 موضوع؛ جلسه بیست‌و‌دوم", "موضوع", 22},
		{"📋 موضوع؛ جلسه بیست و یکم", "موضوع", 21},
		{"📋 موضوع؛ جلسه سی‌ام", "موضوع", 30},
		{"📋 موضوع؛ جلسه صد و دوازدهم", "موضوع", 112},
		{"📋 فاطمیه دقیقاً چیست؟ - جلسه پنجم (جلسه آخر)", "فاطمیه دقیقا چیست؟", 5},
		{"📋 نگاه دینی به جنگ اخیر؛ جلسه بیست و ششم - جهاد خیابان، امید به معیت با امام", "نگاه دینی به جنگ اخیر", 26},
		{"📋 موضوع؛ جلسه ١٢", "موضوع", 12},
		{"📋 عنوان تک‌جلسه‌ای", "عنوان تک جلسه ای", 0},
		{"🎙 #سخنرانی_کامل\n🗓 تاریخ", "", 0},
		{"📋 موضوع؛ جلسه نامشخص", "موضوع", 0},
	} {
		topic, session, _ := Topic(tc.caption)
		if topic != tc.topic || session != tc.session {
			t.Errorf("%q -> %q %d want %q %d", tc.caption, topic, session, tc.topic, tc.session)
		}
	}
}
