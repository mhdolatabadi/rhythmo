package moderation

import "testing"

func TestCheckCatchesObfuscatedWords(t *testing.T) {
	for _, text := range []string{
		"fuck", "FUUUCK this", "f.u.c.k", "f u c k", "sh1t mix", "motherfucker",
		"کیر", "كير", "ک.ی.ر", "ک ی ر", "کیییر", "جنده‌ها", "جـنـده", "کِیر", "این کسکش",
		"=)) dick",
	} {
		if _, hit := Check(text); !hit {
			t.Errorf("Check(%q) missed", text)
		}
	}
}

func TestCheckLeavesOrdinaryWordsAlone(t *testing.T) {
	for _, text := range []string{
		"کسی نمی‌داند", "اکنون", "عکس‌های قدیمی", "گروه موسیقی", "کونگ‌فو پاندا",
		"Dickens audiobook", "Scunthorpe", "cocktail jazz", "shitake? no: shiitake", "classic hits",
		"شب‌های تهران", "موسیقی سنتی", "Cumbia", "",
	} {
		if word, hit := Check(text); hit {
			t.Errorf("Check(%q) flagged %q", text, word)
		}
	}
}

func TestCheckLooksAtEveryText(t *testing.T) {
	if _, hit := Check("fine name", "", "track: fuck"); !hit {
		t.Fatal("a track title was not checked")
	}
}
