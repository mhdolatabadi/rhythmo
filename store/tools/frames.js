const { chromium } = require(require('child_process').execSync('npm root -g').toString().trim() + '/playwright');
const dir = __dirname;
const shots = [
  ['01-library', 'موسیقی من، همه‌جا', 'آپلود کن و با کیفیت اصلی گوش بده'],
  ['02-now-playing', 'پخش‌کننده‌ای خوش‌دست', 'پخش تصادفی، تکرار، صف پخش و زمان‌سنج خواب'],
  ['03-playlists', 'فهرست پخش بساز', 'به اشتراک بگذار یا با دوستانت با هم بسازید'],
  ['04-playlist', 'هر فهرست، به سلیقه‌ی تو', 'ترتیب را بچین، تصادفی پخش کن یا لینکش را بفرست'],
  ['05-search', 'هر آهنگی را فوری پیدا کن', 'جست‌وجو در نام آهنگ، خواننده و آلبوم'],
  ['07-ganjineh', 'گنجینه‌ی ریتمو', 'آهنگ‌های عمومی را بشنو و به «موسیقی من» ببر'],
  ['06-guest', 'فهرست‌های پخش محبوب', 'بدون ثبت‌نام بشنو و با یک لمس بپسند'],
];
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium', args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 } });
  let i = 0;
  for (const [img, t, s] of shots) {
    i++;
    const u = new URL('file://' + dir + '/frame.html');
    u.searchParams.set('t', t); u.searchParams.set('s', s); u.searchParams.set('img', 'raw/' + img + '.png');
    await p.goto(u.href);
    await p.evaluate(() => document.fonts.ready);
    await p.waitForFunction(() => document.getElementById('img').complete);
    await p.waitForTimeout(200);
    await p.screenshot({ path: `${dir}/../listing/screenshot-${i}.png` });
  }
  await b.close();
})();
