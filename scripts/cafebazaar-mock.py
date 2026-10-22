#!/usr/bin/env python3
# A fake Pishkhan release API for scripts/test-publish-cafebazaar.sh.
import http.server, json, sys
state = {"pending": sys.argv[2] == "pending", "fail_upload": sys.argv[3] == "fail", "missing": sys.argv[2] in ("missing", "missing-persistent"), "persistent": sys.argv[2] == "missing-persistent"}
log = open(sys.argv[4], "a")
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def check(self):
        ok = self.headers.get("CAFEBAZAAR-PISHKHAN-API-SECRET") == "s3cret"
        log.write(f"{self.command} {self.path} auth={ok}\n"); log.flush()
        return ok
    def do_GET(self):
        if not self.check(): return self.reply({"type":"error"}, 401)
        self.reply({"type": "success" if state["missing"] else ("exists" if state["pending"] else "not-exists"), "message": "checked"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); data = self.rfile.read(n)
        if not self.check(): return self.reply({"type":"error"}, 401)
        if self.path == "/v1/apps/releases/":
            state["missing"] = state["persistent"]
        if self.path == "/v1/apps/releases/upload/":
            if state["missing"]: return self.reply({"type":"error","message":"رهانش ثبت ‌شده‌ای وجود ندارد."}, 400)
            ok = (b'name="apk"' in data and b"APKDATA" in data
                  and b"Content-Type: application/vnd.android.package-archive\r\n" in data
                  and b'name="architecture"\r\n\r\nall\r\n' in data)
            if state["fail_upload"]: return self.reply({"type":"error","message":"version code must increase"})
            return self.reply({"type":"success" if ok else "error","message":"uploaded"})
        if self.path == "/v1/apps/releases/commit/":
            log.write("commit " + data.decode() + "\n"); log.flush()
        self.reply({"type":"success","message":"ok"})
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
