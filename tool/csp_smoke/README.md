# CSP smoke test (#218)

Checks that the web app works under the Content-Security-Policy in
`deploy/nginx.conf`: it loads, signs in, lists the library and plays a song
from an https storage URL, while every `securitypolicyviolation` is
recorded. The API and storage are mocked with Playwright routes.

```sh
flutter build web --release --no-web-resources-cdn --base-href /app/
ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -b:a 64k tool/csp_smoke/song.mp3
grep -o 'Content-Security-Policy "[^"]*"' deploy/nginx.conf | head -1 | cut -d'"' -f2 > /tmp/csp.txt
python3 tool/csp_smoke/serve.py build/web /tmp/csp.txt &
FORM='[[195,407],[195,467]]' ROW='[250,288]' node tool/csp_smoke/smoke.js
```

`CSP events []` means no violations. `FORM` and `ROW` are the tap points of
the email/password fields and the first song at 390×844; update them if
the sign-in or library layout moves. Screenshots land next to the script.
