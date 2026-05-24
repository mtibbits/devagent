#!/usr/bin/env python3
"""Tiny route-table fixture HTTP server for backend contract tests.

Usage: server.py <fixture-dir> <port> <request-log>

Routes are read from <fixture-dir>/routes.json. Each key is
"<METHOD> <PATH>" and each value is one of:
  {"status": N, "body": "..."}
  {"status": N, "body_file": "relative-to-fixture-dir.json"}
  {"status": N, "body_file": "...", "headers": {"Content-Type": "..."}}

Every incoming request is appended one-line to <request-log>:
  <METHOD> <PATH>\\t<body-as-one-line>

The server is single-threaded and exits on SIGTERM.
"""

import json
import os
import sys
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    fixture_dir = sys.argv[1]
    port = int(sys.argv[2])
    request_log = sys.argv[3]

    routes_path = os.path.join(fixture_dir, "routes.json")
    with open(routes_path) as f:
        routes = json.load(f)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _serve(self, method):
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length) if length else b""
            try:
                with open(request_log, "a") as rl:
                    rl.write("%s %s\t%s\n" %
                             (method, self.path, body.decode("utf-8", "replace")))
            except OSError:
                pass

            key = "%s %s" % (method, self.path)
            spec = routes.get(key)
            if spec is None:
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":"no fixture for ' + key.encode() + b'"}')
                return

            status = int(spec.get("status", 200))
            headers = spec.get("headers", {"Content-Type": "application/json"})
            if "body_file" in spec:
                with open(os.path.join(fixture_dir, spec["body_file"]), "rb") as bf:
                    payload = bf.read()
            else:
                payload = spec.get("body", "").encode("utf-8")

            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):    self._serve("GET")
        def do_POST(self):   self._serve("POST")
        def do_PUT(self):    self._serve("PUT")
        def do_PATCH(self):  self._serve("PATCH")
        def do_DELETE(self): self._serve("DELETE")

    server = HTTPServer(("127.0.0.1", port), Handler)

    def stop(_signum, _frame):
        server.shutdown()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever()


if __name__ == "__main__":
    main()
