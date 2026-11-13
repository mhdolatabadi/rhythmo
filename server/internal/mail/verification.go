package mail

import (
	"html"

	"github.com/mhdolatabadi/rhythmo/server/internal/display"
)

// VerificationCode is the Persian email that carries an account's code.
func VerificationCode(to, code string, validMinutes int) Message {
	return codeMessage(to, "کد تأیید ایمیل ریتمو", "کد تأیید ایمیل شما در ریتمو:", code, validMinutes,
		"اگر شما در ریتمو ثبت‌نام نکرده‌اید، این ایمیل را نادیده بگیرید.")
}

// SignupCode is the Persian email that finishes a sign-up (#219).
func SignupCode(to, code string, validMinutes int) Message {
	return codeMessage(to, "کد ثبت‌نام ریتمو", "کد ثبت‌نام شما در ریتمو:", code, validMinutes,
		"اگر شما در ریتمو ثبت‌نام نکرده‌اید، این ایمیل را نادیده بگیرید.")
}

// PasswordResetCode is the Persian email that lets someone set a new
// password (#380).
func PasswordResetCode(to, code string, validMinutes int) Message {
	return codeMessage(to, "کد تغییر رمز عبور ریتمو", "کد تغییر رمز عبور شما در ریتمو:", code, validMinutes,
		"اگر شما درخواست تغییر رمز نداده‌اید، این ایمیل را نادیده بگیرید؛ رمزتان عوض نمی‌شود.")
}

// SignupAttempt tells the owner of an address that someone tried to
// register it again (#219), instead of a code.
func SignupAttempt(to string) Message {
	lines := []string{
		"کسی تلاش کرد با این ایمیل در ریتمو ثبت‌نام کند، اما این ایمیل از قبل حساب دارد.",
		"اگر خودتان بودید، با همین ایمیل وارد شوید. اگر رمز را فراموش کرده‌اید، در صفحه‌ی ورود «رمز را فراموش کرده‌ای؟» را بزنید.",
		"اگر شما نبودید، کاری لازم نیست؛ حسابتان تغییری نکرده است.",
	}
	text := "سلام،\n\n" + lines[0] + "\n\n" + lines[1] + "\n" + lines[2] + "\n\nریتمو\n"
	body := `<p style="margin:0 0 16px">سلام،</p>
<p style="margin:0 0 16px">` + lines[0] + `</p>
<p style="margin:0 0 8px">` + lines[1] + `</p>
<p style="margin:0;color:#a9afbd">` + lines[2] + `</p>`
	return Message{To: to, Subject: "تلاش برای ثبت‌نام با ایمیل شما در ریتمو", Text: text, HTML: page("ثبت‌نام ریتمو", body)}
}

func codeMessage(to, subject, intro, code string, validMinutes int, ignore string) Message {
	minutes := display.PersianDigits(validMinutes)
	text := "سلام،\n\n" +
		intro + "\n\n" +
		code + "\n\n" +
		"این کد تا " + minutes + " دقیقه معتبر است. آن را در برنامه وارد کنید.\n" +
		ignore + "\n\n" +
		"ریتمو\n"
	body := `<p style="margin:0 0 16px">سلام،</p>
<p style="margin:0 0 16px">` + intro + `</p>
<p dir="ltr" style="margin:0 0 16px;font-size:32px;font-weight:700;letter-spacing:8px;text-align:center">` + html.EscapeString(code) + `</p>
<p style="margin:0 0 8px">این کد تا ` + minutes + ` دقیقه معتبر است. آن را در برنامه وارد کنید.</p>
<p style="margin:0;color:#a9afbd">` + ignore + `</p>`
	return Message{To: to, Subject: subject, Text: text, HTML: page(subject, body)}
}

func page(title, body string) string {
	return `<!doctype html>
<html lang="fa" dir="rtl">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>` + title + `</title></head>
<body dir="rtl" style="margin:0;padding:24px;background:#0b0d12;color:#eef0f5;font-family:Vazirmatn,Tahoma,sans-serif;text-align:right">
<div style="max-width:480px;margin:0 auto;padding:24px;border-radius:20px;background:#161a23">
` + body + `
</div>
</body>
</html>
`
}
