#!/usr/bin/env python3
"""Local HTTP server for manual testing of OleDownloadManager (development only).

Usage:  python3 Scripts/dev-server.py [port]          (default port 8765, binds 127.0.0.1)

Endpoints (all content is generated, nothing is read from disk):
  /file/<name>?size=BYTES&rate=BYTES_PER_SEC&ranges=0|1&fail=N
      Deterministic file. Honors Range/If-Range unless ranges=0. `rate` throttles each
      connection (default unlimited). `fail=N` answers 503 to the first N requests.
  /status/<code>          Any HTTP status, e.g. /status/404 or /status/401
  /redirect/<name>?...    302 to /file/<name>?...
"""
import sys, time, threading, re
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs, quote, unquote

counters = {}
lock = threading.Lock()

def byte_at(i, seed):
    return ((i * 31) ^ (i >> 7)) + seed * 17 & 0xFF

def body(start, end, seed):
    return bytes(byte_at(i, seed) & 0xFF for i in range(start, end + 1))

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def do_HEAD(self):
        self.handle_request(head=True)

    def do_GET(self):
        self.handle_request(head=False)

    def handle_request(self, head):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path.startswith("/status/"):
            code = int(url.path.split("/")[-1])
            self.send_response(code); self.send_header("Content-Length", "0"); self.send_header("Connection", "close"); self.end_headers(); return
        if url.path.startswith("/redirect/"):
            self.send_response(302); self.send_header("Location", "/file/" + url.path.split("/", 2)[2] + ("?" + url.query if url.query else ""))
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if not url.path.startswith("/file/"):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        name = unquote(url.path.split("/", 2)[2]) or "download.bin"
        size = int(q.get("size", "10485760"))
        rate = int(q.get("rate", "0"))
        seed = len(name)
        fails = int(q.get("fail", "0"))
        if fails:
            with lock:
                counters[self.path] = counters.get(self.path, 0) + 1
                n = counters[self.path]
            if n <= fails:
                self.send_response(503); self.send_header("Retry-After", "2"); self.send_header("Content-Length", "0"); self.end_headers(); return
        etag = '"%d-%d"' % (size, seed)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if q.get("ranges", "1") == "1" and rng and (self.headers.get("If-Range") in (None, etag)):
            m = re.match(r"bytes=(\d*)-(\d*)$", rng)
            if m:
                a, b = m.group(1), m.group(2)
                if a == "": start, end = max(0, size - int(b)), size - 1
                else: start, end = int(a), min(int(b) if b else size - 1, size - 1)
                if start >= size or start > end:
                    self.send_response(416); self.send_header("Content-Range", "bytes */%d" % size); self.send_header("Content-Length", "0"); self.end_headers(); return
                status = 206
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", "Tue, 01 Sep 2026 10:00:00 GMT")
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + quote(name))
        if q.get("ranges", "1") == "1": self.send_header("Accept-Ranges", "bytes")
        if status == 206: self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if head: return
        chunk = 65536
        pos = start
        t0 = time.time()
        try:
            while pos <= end:
                n = min(chunk, end - pos + 1)
                self.wfile.write(body(pos, pos + n - 1, seed))
                pos += n
                if rate > 0:
                    expected = (pos - start) / rate
                    elapsed = time.time() - t0
                    if expected > elapsed: time.sleep(expected - elapsed)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print("OleDownloadManager dev server on http://127.0.0.1:%d" % port, flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
