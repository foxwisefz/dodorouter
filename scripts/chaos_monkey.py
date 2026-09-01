#!/usr/bin/env python3
"""Chaos proxy for demonstrating midstream provider failover.

Sits between the z.ai adapter and api.z.ai. Relays the real streaming
response, then abruptly kills the client connection (TCP RST) after
KILL_AFTER content-bearing SSE events — mid-answer, before [DONE] and
before the terminating chunked-encoding frame. Finch surfaces that as a
transport error, the z.ai adapter reports partial_content/chunks_sent,
and FallbackChain hands the reconstructed request to the next step.

Usage:
    python3 scripts/chaos_zai_proxy.py            # kill after ~200 chars of text
    KILL_AFTER_CHARS=500 python3 scripts/chaos_zai_proxy.py
    CHAOS_OFF=1 python3 scripts/chaos_zai_proxy.py  # pure passthrough (sanity check)

Point the adapter at it by rewriting Adapters.Zai's base URLs to
http://localhost:9911 (temporary dev edit; the path is forwarded as-is).
"""

import http.client
import http.server
import os
import re
import socket
import socketserver
import struct
import sys
import threading
import time

LISTEN_PORT = int(os.environ.get("PORT", "9911"))
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "api.z.ai")
KILL_AFTER_CHARS = int(os.environ.get("KILL_AFTER_CHARS", "200"))
CHAOS_OFF = os.environ.get("CHAOS_OFF") == "1"

# Visible text inside an SSE delta: OpenAI-style {"delta":{"content":"..."}}
# or Anthropic-style text_delta {"text":"..."}. The kill threshold counts
# CHARACTERS of this text, not events — providers chunk differently (Opus
# batches big deltas, Kimi sends word-sized ones), so an event count is not
# comparable across them. Thinking deltas ("thinking":...) deliberately do
# not count — the kill should land after text the viewer can see.
CONTENT_RE = re.compile(rb'"(?:content|text)"\s*:\s*"((?:[^"\\]|\\.)*)"')

HOP_HEADERS = {
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "keep-alive",
    "te",
    "upgrade",
    "proxy-authorization",
}


def log(msg):
    print(f"[chaos] {time.strftime('%H:%M:%S')} {msg}", flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet the default access log
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        headers = {
            k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS
        }
        headers["Host"] = UPSTREAM_HOST
        headers["Accept-Encoding"] = "identity"

        log(f"POST {self.path} -> https://{UPSTREAM_HOST} ({length} bytes)")

        conn = http.client.HTTPSConnection(UPSTREAM_HOST, timeout=120)
        try:
            conn.request("POST", self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except Exception as e:
            log(f"upstream error: {e}")
            self.send_error(502, f"chaos proxy upstream error: {e}")
            conn.close()
            return

        ctype = resp.getheader("Content-Type", "application/json")
        streaming = "text/event-stream" in ctype

        self.send_response(resp.status)
        self.send_header("Content-Type", ctype)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        content_chars = 0
        killed = False
        try:
            while True:
                data = resp.read1(65536)
                if not data:
                    break
                self._write_chunk(data)
                if streaming and not CHAOS_OFF:
                    content_chars += sum(len(m) for m in CONTENT_RE.findall(data))
                    if content_chars >= KILL_AFTER_CHARS:
                        killed = True
                        break
        except Exception as e:
            log(f"relay error: {e}")

        conn.close()

        if killed:
            log(
                f"KILLED stream after {content_chars} chars of text "
                f"(status {resp.status})"
            )
            self._rst_close()
        else:
            # Clean finish: terminal chunk so the client sees a proper end.
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except Exception:
                pass
            log(f"relayed cleanly (status {resp.status}, {content_chars} chars of text)")

    def _write_chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def _rst_close(self):
        # SO_LINGER(1, 0): close() sends RST instead of FIN, guaranteeing the
        # proxy's HTTP client reports a transport error rather than a clean EOF.
        try:
            self.connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
        except OSError:
            pass
        try:
            self.connection.close()
        except OSError:
            pass
        # Stop BaseHTTPRequestHandler from touching the dead socket again.
        self.close_connection = True
        self.wfile = open(os.devnull, "wb")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    mode = "PASSTHROUGH (CHAOS_OFF=1)" if CHAOS_OFF else f"kill after {KILL_AFTER_CHARS} chars of text"
    log(f"listening on :{LISTEN_PORT}, upstream https://{UPSTREAM_HOST}, mode: {mode}")
    try:
        Server(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
