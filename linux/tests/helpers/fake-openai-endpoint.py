#!/usr/bin/env python3
"""A provider that misbehaves on purpose — the harness-evaluation probe.

    fake-openai-endpoint.py ratelimit [port]   # always HTTP 429, no Retry-After
    fake-openai-endpoint.py nousage   [port]   # streams fine, omits `usage`
    fake-openai-endpoint.py toolcall  [port]   # calls the named tool once, then stops

WHY THIS EXISTS. On 2026-09-02 a rate-limited endpoint cost an evening:
opencode recorded each 429 as a contentless step and retried forever, so
the failure was invisible and self-sustaining (the retries were the load).
Diagnosing that against the live provider meant ADDING to the load, and
the second failure mode — a provider that never returns a `usage` object,
which silently disables every context meter and auto-compaction — cannot
be triggered on demand at all.

So the failure modes moved here. Each is reproducible in a second, costs
no tokens, and touches nobody's quota. Point any agent CLI at it and read
what it does:

    ~/.pi/agent/models.json          (pi)
    provider.<name>.options.baseURL  (opencode)
    custom_providers[]               (hermes)

WHAT GOOD BEHAVIOUR LOOKS LIKE, measured 2026-09-03 (features/17):
  ratelimit → pi: 4 attempts, 2s/4s/8s backoff, then the provider's own
              error text and a non-zero exit.
              opencode: 2,785 contentless turns out of 3,314, no exit.
  nousage   → pi reports zeros and keeps going; opencode's meter dies
              silently and compaction never fires.
  toolcall  → proves an extension's tool is registered, offered, and
              executed, without needing a model that can be trusted to
              call it (a slow local model produced nothing in 8 minutes).

TRAP, paid for: use ThreadingHTTPServer. The single-threaded one wedges
on a half-read connection and then ACCEPTS but never answers — which
reads exactly like the client hanging, and cost three wrong diagnoses.
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[1] if len(sys.argv) > 1 else "nousage"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else {"ratelimit": 8471, "nousage": 8472, "toolcall": 8473}[MODE]
TOOL = os.environ.get("FAKE_TOOL_NAME", "cmux_letter")
TOOL_ARGS = os.environ.get("FAKE_TOOL_ARGS", '{"probe": "hello"}')
LOG = os.environ.get("FAKE_LOG", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-endpoint.log"))
STATE = {"tool_called": False}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self._json(200, {"object": "list", "data": [{"id": "fake-1", "object": "model"}]})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        # Recording what the client SENT is half the value: which tools it
        # offered, whether it asked for usage, what it capped output at.
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "t": round(time.time(), 3),
                "mode": MODE,
                "tools": [t.get("function", {}).get("name") for t in body.get("tools", [])],
                "stream": body.get("stream"),
                "stream_options": body.get("stream_options"),
                "max_tokens": body.get("max_tokens") or body.get("max_completion_tokens"),
            }) + "\n")

        if MODE == "ratelimit":
            # No Retry-After and no rate-limit headers — the shape observed
            # on the real endpoint, which leaves a client nothing to back
            # off intelligently on.
            self._json(429, {"error": {"message": "Too Many Requests", "type": "rate_limit"}})
            return

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()

        def sse(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()

        def chunk(delta, finish=None):
            return {"id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0,
                    "model": "fake-1",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

        if MODE == "toolcall" and not STATE["tool_called"]:
            STATE["tool_called"] = True
            sse(chunk({"tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                                       "function": {"name": TOOL, "arguments": TOOL_ARGS}}]}))
            sse(chunk({}, "tool_calls"))
        else:
            for piece in ("pong ", "from ", "the ", "fake ", "endpoint"):
                sse(chunk({"content": piece}))
            sse(chunk({}, "stop"))
        # NOTE: no usage chunk, in every mode. That is deliberate.
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


if __name__ == "__main__":
    print(f"fake endpoint: mode={MODE} port={PORT} tool={TOOL} log={LOG}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
