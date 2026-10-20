// Run against HTML exported by TestPublicDesignPreview; no live/private data.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
  const dir = process.env.RHYTHMO_PUBLIC_PREVIEW_DIR;
  assert.ok(dir, 'RHYTHMO_PUBLIC_PREVIEW_DIR is required');
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined,
    headless: true,
  });
  try {
    for (const file of fs.readdirSync(dir).filter((name) => name.endsWith('.html'))) {
      for (const width of [360, 1280]) {
        const page = await browser.newPage({ viewport: { width, height: 900 } });
        // Keep this check independent from media and external services.
        await page.route('**/*', (route) => route.abort());
        await page.setContent(fs.readFileSync(path.join(dir, file), 'utf8'));
        const bounds = await page.evaluate(() => ({
          scroll: document.documentElement.scrollWidth,
          main: document.querySelector('main').getBoundingClientRect().width,
          targets: [...document.querySelectorAll('.button, .brand, footer a, input, a.grow')]
            .map((node) => node.getBoundingClientRect().height),
        }));
        assert.ok(bounds.scroll <= width, `${file} overflows at ${width}: ${bounds.scroll}`);
        assert.ok(bounds.main <= 960, `${file} exceeds the content cap`);
        assert.ok(bounds.targets.every((height) => height >= 48), `${file} has a short touch target`);
        await page.keyboard.press('Tab');
        assert.equal(await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle), 'solid');
        await page.screenshot({ path: path.join(dir, `${file}-${width}.png`), fullPage: true });
        console.log(`${file}: ${width}px, no overflow, content capped, targets and focus pass`);
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
