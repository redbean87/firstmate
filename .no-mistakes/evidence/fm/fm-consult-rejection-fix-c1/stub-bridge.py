import http.server, json, os, sys
PORT = int(sys.argv[1])
MODEFILE = sys.argv[2]
LOG = sys.argv[3]

def mode():
    try:
        return open(MODEFILE).read().strip() or "ok"
    except FileNotFoundError:
        return "ok"

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        try:
            req = json.loads(body.decode() or "{}")
        except Exception:
            req = {"_raw": body.decode(errors="replace")[:200]}
        m = mode()
        with open(LOG, "a") as f:
            f.write(json.dumps({"mode": m, "path": self.path,
                "model": req.get("model"), "auth": self.headers.get("authorization")}) + "\n")
        if m == "ok":
            payload = {"output": [{"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "STUB ANSWER: proceed with the plan"}]}]}
            self.send_response(200)
        elif m == "reject200":
            payload = {"error": {"code": "context_length_exceeded",
                "message": "This request exceeds the browser transport budget (102400 tokens)."}}
            self.send_response(200)
        elif m == "reject_nosize":
            payload = {"error": {"message": "bridge refused this turn outright"}}
            self.send_response(200)
        elif m == "error_no_message":
            payload = {"error": {"code": "weird_bridge_state"}}
            self.send_response(200)
        elif m == "http500":
            payload = {"error": {"message": "stub failure"}}
            self.send_response(500)
        elif m == "garbage":
            b = b"not json at all"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        else:
            payload = {"error": {"message": "unknown mode " + m}}
            self.send_response(500)
        b = json.dumps(payload).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
