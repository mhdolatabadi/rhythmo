package bot

import (
	"fmt"

	"github.com/mhdolatabadi/rhythmo/server/internal/display"
)

// Everything the bots say, in one place.
const (
	msgWelcome     = "سلام! این ربات ریتمو است. فایل‌های صوتی را اینجا بفرستید تا به «موسیقی من» در ریتمو اضافه شوند.\n\n" + msgHowToLink
	msgHowToLink   = "برای اتصال حساب ریتمو: در اپ ریتمو به «تنظیمات ← اتصال به بات» بروید، «دریافت کد» را بزنید و کد ۸ رقمی را همین‌جا بفرستید."
	msgBadCode     = "این کد درست نیست یا منقضی شده است. از اپ ریتمو کد تازه بگیرید و دوباره بفرستید."
	msgLocked      = "چند بار کد اشتباه فرستاده‌اید. یک ساعت دیگر دوباره امتحان کنید."
	msgUnlinked    = "اتصال این گفتگو به حساب ریتمو قطع شد. برای اتصال دوباره، از اپ ریتمو کد تازه بگیرید."
	msgNotLinked   = "این گفتگو هنوز به حساب ریتمو وصل نیست.\n\n" + msgHowToLink
	msgPrivateOnly = "ربات ریتمو فقط در گفتگوی خصوصی کار می‌کند."
	msgHelp        = "فایل صوتی (mp3، m4a، flac، ogg، wav و …) بفرستید تا به «موسیقی من» در ریتمو اضافه شود.\n\n" +
		"/status حساب متصل\n/logout قطع اتصال\n/help همین راهنما\n\n" + msgHowToLink
	msgTryAgain  = "مشکلی پیش آمد. کمی بعد دوباره امتحان کنید."
	msgSendAudio = "فایل صوتی بفرستید، یا /help را ببینید."
	msgQueued    = "فایل دریافت شد و در حال اضافه شدن به «موسیقی من» است…"
)

func msgLinked(email string) string {
	return fmt.Sprintf("این گفتگو به حساب %s وصل شد. حالا فایل صوتی بفرستید.", email)
}

func msgStatus(email string) string {
	return fmt.Sprintf("این گفتگو به حساب %s وصل است. فایل‌های صوتی که می‌فرستید به «موسیقی من» در همین حساب اضافه می‌شوند.", email)
}

func msgImported(title string) string {
	return fmt.Sprintf("«%s» به «موسیقی من» در ریتمو اضافه شد.", title)
}

func msgRefused(reason string, maxMB int64) string {
	switch reason {
	case ReasonUnsupported:
		return "این فایل پشتیبانی نمی‌شود. فایل صوتی mp3، m4a، aac، flac، ogg، opus، wav یا webm بفرستید."
	case ReasonTooLarge:
		return fmt.Sprintf("حجم فایل بیشتر از %s مگابایت است و از طریق ربات قابل دریافت نیست.", display.PersianDigits(maxMB))
	case ReasonQuota:
		return "فضای «موسیقی من» پر است. برای افزودن آهنگ تازه، چند آهنگ را از آن حذف کنید."
	case ReasonPending:
		return "چند فایل در حال اضافه شدن است. صبر کنید تمام شوند و دوباره بفرستید."
	case ReasonDisabled:
		return "افزودن آهنگ فعلاً غیرفعال است. کمی بعد دوباره امتحان کنید."
	case ReasonInvalid:
		return "محتوای این فایل با قالبش جور نیست یا فایل صوتی سالمی نیست."
	default:
		return "افزودن این فایل ناموفق بود. دوباره بفرستید."
	}
}

func msgSendFailed(title string) string {
	return fmt.Sprintf("فرستادن «%s» از ریتمو ناموفق بود. کمی بعد دوباره از اپ امتحان کنید.", title)
}

func msgSendTooLarge(title string, maxMB int64) string {
	return fmt.Sprintf("«%s» بیشتر از %s مگابایت است و ربات نمی‌تواند آن را بفرستد.", title, display.PersianDigits(maxMB))
}

// msgPlaylistTracksAdded tells a subscriber what was added to a public
// playlist; link, when known, opens it.
func msgPlaylistTracksAdded(playlist string, count int, latest *string, link string) string {
	var text string
	if count == 1 && latest != nil {
		text = fmt.Sprintf("«%s» به پلی‌لیست «%s» اضافه شد.", *latest, playlist)
	} else {
		text = fmt.Sprintf("%s صوت تازه به پلی‌لیست «%s» اضافه شد.", display.PersianDigits(int64(count)), playlist)
	}
	if link != "" {
		text += "\n\n" + link
	}
	return text
}
