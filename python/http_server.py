#!/usr/bin/env python3
"""Bearer-protected Streamable HTTP front for reaper-mcp stdio."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("REAPER_MCP_PORT", "8787"))
BEARER = os.environ.get("REAPER_MCP_BEARER", "")
ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "python" / "server.py"


class StdioClient:
    def __init__(self) -> None:
        env = os.environ.copy()
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self.lock = threading.Lock()

    def rpc(self, msg: dict):
        line = json.dumps(msg, ensure_ascii=False)
        with self.lock:
            if self.proc.poll() is not None:
                raise RuntimeError("stdio MCP exited")
            assert self.proc.stdin and self.proc.stdout
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()
            if msg.get("id") is None:
                return None
            while True:
                out = self.proc.stdout.readline()
                if not out:
                    raise RuntimeError("stdio MCP closed stdout")
                out = out.strip()
                if not out:
                    continue
                return json.loads(out)


CLIENT = StdioClient()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: bytes, content_type: str, extra: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _unauthorized(self) -> None:
        self._send(
            401,
            b'{"error":"unauthorized"}',
            "application/json",
            {"WWW-Authenticate": 'Bearer realm="reaper-mcp"'},
        )

    def _auth_ok(self) -> bool:
        if not BEARER:
            return False
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {BEARER}"

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] in ("/healthz", "/health"):
            self._send(200, b'{"ok":true}', "application/json")
            return
        if not self._auth_ok():
            self._unauthorized()
            return
        self._send(405, b'{"error":"use POST"}', "application/json")

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path not in ("/", "/mcp"):
            self._send(404, b'{"error":"not found"}', "application/json")
            return
        if not self._auth_ok():
            self._unauthorized()
            return
        n = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            msg = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            self._send(400, b'{"error":"invalid json"}', "application/json")
            return
        try:
            result = CLIENT.rpc(msg)
        except Exception as e:  # noqa: BLE001
            err = json.dumps({"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32603, "message": str(e)}})
            self._send(200, err.encode("utf-8"), "application/json")
            return
        if result is None:
            self._send(202, b"", "application/json")
            return
        self._send(200, json.dumps(result, ensure_ascii=False).encode("utf-8"), "application/json")


def main() -> None:
    if not BEARER:
        raise SystemExit("REAPER_MCP_BEARER is not set")
    if not SERVER.is_file():
        raise SystemExit(f"missing {SERVER}")
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"reaper-mcp http on 127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
