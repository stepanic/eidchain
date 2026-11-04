"""Serves the OTA install page for the phone and receives probe logs.

Runs on 127.0.0.1 behind `tailscale serve`, which supplies the HTTPS certificate
that iOS requires for itms-services installs. Only tailnet devices can reach it.
"""
import http.server, os, sys, time

ROOT = sys.argv[1]          # dir with EOINFC.ipa and manifest.plist
LOGS = sys.argv[2]          # dir where POSTed logs land
BASE = "https://ms.tailf0e6eb.ts.net/eoinfc"
PAGE = f"""<!doctype html><meta name=viewport content="width=device-width">
<h2>eOI NFC</h2><p><a href="itms-services://?action=download-manifest&url={BASE}/manifest.plist">Instaliraj</a></p>
<p>Build: {{built}}</p>"""

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def _path(self):
        p = self.path.split("?")[0]
        return p[len("/eoinfc"):] if p.startswith("/eoinfc") else p
    def do_GET(self):
        p = self._path()
        if p in ("", "/"):
            ipa = os.path.join(ROOT, "EOINFC.ipa")
            built = time.ctime(os.path.getmtime(ipa)) if os.path.exists(ipa) else "nema"
            body = PAGE.replace("{built}", built).encode()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        self.path = p
        super().do_GET()
    def do_POST(self):
        if self._path() != "/log": self.send_error(404); return
        n = min(int(self.headers.get("Content-Length", 0)), 1 << 20)
        name = time.strftime("%Y%m%d-%H%M%S") + ".txt"
        with open(os.path.join(LOGS, name), "wb") as f: f.write(self.rfile.read(n))
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def guess_type(self, path):
        if path.endswith(".plist"): return "application/xml"
        if path.endswith(".ipa"): return "application/octet-stream"
        return super().guess_type(path)

os.makedirs(LOGS, exist_ok=True)
http.server.ThreadingHTTPServer(("127.0.0.1", 8787), H).serve_forever()
