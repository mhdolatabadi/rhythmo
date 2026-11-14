import http.server, os, sys
ROOT = sys.argv[1]; CSP = open(sys.argv[2]).read().strip()
class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        p = path.split('?')[0]
        if p.startswith('/app/'): p = p[4:]
        full = os.path.join(ROOT, p.lstrip('/'))
        if not os.path.exists(full) or os.path.isdir(full) and not os.path.exists(os.path.join(full,'index.html')):
            full = os.path.join(ROOT, 'index.html')
        return full
    def end_headers(self):
        self.send_header('Content-Security-Policy', CSP)
        super().end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', 8099), H).serve_forever()
