#!/usr/bin/env python3
"""Make a non-streaming upstream usable by agent CLIs that only stream.

    unstream-proxy.py https://chat.s.regio-ai.eu/api/v1 [port]

Listens on 127.0.0.1:<port> (default 8480), speaks the OpenAI-compatible
surface, and for a streamed request it calls the upstream WITHOUT
`stream`, then re-emits the answer as SSE chunks the client expects.

WHY: measured 2026-09-03, `chat.s.regio-ai.eu` returns an EMPTY stream
for every model it advertises — connection accepted, closed cleanly, no
chunks, no `[DONE]`, no error — while the identical non-streamed request
answers correctly with usage. Every agent CLI streams, so the provider is
unusable by all of them at once; a plain HTTP client is fine. This shim
sits in between until the operator fixes it (UPSTREAM.md §5d).

It is deliberately dumb: no auth of its own (the client's Authorization
header is forwarded), no retries, no caching, no rewriting beyond
dropping `stream`/`stream_options` and re-emitting. Throw it away when
upstream streams again.

Point any harness at it:
    pi        ~/.pi/agent/models.json      baseUrl http://127.0.0.1:8480
    opencode  provider.<n>.options.baseURL  same
    hermes    custom_providers[].base_url   same
"""
import json, sys, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "https://chat.s.regio-ai.eu/api/v1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8480


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _upstream(self, path, body, headers):
        req = urllib.request.Request(UPSTREAM + path, data=body, method="POST" if body else "GET")
        for h in ("authorization", "content-type"):
            if headers.get(h):
                req.add_header(h, headers[h])
        return urllib.request.urlopen(req, timeout=300)

    def do_GET(self):
        try:
            with self._upstream(self.path.replace("/v1", "", 1) or "/models", None, self.headers) as r:
                raw = r.read()
            self._send(200, raw, "application/json")
        except urllib.error.HTTPError as e:
            self._send(e.code, e.read(), "application/json")

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        wanted_stream = bool(body.pop("stream", False))
        body.pop("stream_options", None)          # meaningless without a stream
        path = self.path.replace("/v1", "", 1) or "/chat/completions"
        try:
            with self._upstream(path, json.dumps(body).encode(), self.headers) as r:
                answer = json.loads(r.read())
        except urllib.error.HTTPError as e:
            # Pass the upstream's own error through untouched: a client that
            # can classify a 429 (pi does) must still see the 429.
            self._send(e.code, e.read(), "application/json")
            return

        if not wanted_stream:
            self._send(200, json.dumps(answer).encode(), "application/json")
            return

        choice = (answer.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        def sse(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()

        base = {"id": answer.get("id", "chatcmpl-unstream"), "object": "chat.completion.chunk",
                "created": answer.get("created", 0), "model": answer.get("model", body.get("model"))}
        # role first, then content, then tool calls — the order a client's
        # accumulator expects.
        sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
        if message.get("content"):
            sse({**base, "choices": [{"index": 0, "delta": {"content": message["content"]},
                                      "finish_reason": None}]})
        if message.get("tool_calls"):
            sse({**base, "choices": [{"index": 0, "delta": {"tool_calls": message["tool_calls"]},
                                      "finish_reason": None}]})
        sse({**base, "choices": [{"index": 0, "delta": {},
                                  "finish_reason": choice.get("finish_reason", "stop")}]})
        if answer.get("usage"):
            # The usage the upstream DID return, delivered the way a streaming
            # client asked for it — which is how the context meter comes back.
            sse({**base, "choices": [], "usage": answer["usage"]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _send(self, code, raw, ctype):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    print(f"unstream-proxy: 127.0.0.1:{PORT} -> {UPSTREAM}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
