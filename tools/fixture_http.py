"""Loopback-only CI fixture; no external media, credentials or content keys."""
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

ROOT = Path(sys.argv[1]).resolve()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/health':
            body, code, kind, encoding = b'fixture ready', 200, 'text/plain', None
        elif path == '/redirect.php':
            self.send_response(302)
            self.send_header('Location', '/gzip/manifest.mpd')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        else:
            # Incorrect redirect-base resolution must fail, not hit a root alias.
            relative = path.removeprefix('/gzip/') if path.startswith('/gzip/') else '_missing_'
            target = (ROOT / relative).resolve()
            if ROOT not in target.parents or not target.is_file():
                body, code, kind, encoding = b'missing fixture', 404, 'text/plain', None
            else:
                body, code = target.read_bytes(), 200
                kind = 'application/dash+xml' if target.suffix == '.mpd' else 'video/iso.segment'
                encoding = 'gzip' if path.startswith('/gzip/') and target.suffix == '.mpd' else None
                if encoding:
                    body = gzip.compress(body)
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        if encoding:
            self.send_header('Content-Encoding', encoding)
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('127.0.0.1', 18761), Handler).serve_forever()
