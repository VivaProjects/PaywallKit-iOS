"""仅供 SDK 弱网测试使用；启动后另一个终端执行 xcodebuild test。"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import threading

attempts = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, b"ok")
        if self.path.startswith("/bad/"):
            return self.reply(404, b"")
        if self.path.startswith("/flaky/") and self.path.endswith("package.json"):
            with lock:
                attempts[self.path] = attempts.get(self.path, 0) + 1
                attempt = attempts[self.path]
            if attempt <= 2:
                return self.reply(503, b"")
        parts = self.path.split("/")
        name, identity = parts[-1], parts[-2]
        files = {"offline.html": b"<html>fixture</html>", "offline.js": b"",
                 "content.json": b"{}", "page.json": b"{}"}
        manifest = {
            "formatVersion": 1, "runtimeEnvironment": "test",
            "document": {
                "kind": "web-paywall", "bridgeVersion": 2, "documentId": identity,
                "revision": 2 if self.path.startswith("/v2/") else 1,
                "pageUrl": f"http://127.0.0.1:18931/{identity}/index.html",
                "catalogKey": "default", "productRefs": ["product"],
                "initialProductRef": "product",
            },
            "entry": "offline.html",
            "files": [{"path": key, "size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
                      for key, value in files.items()],
        }
        data = json.dumps(manifest).encode() if name == "package.json" else files.get(name, b"")
        self.reply(200, data)

    def reply(self, status, data):
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    try:
        ThreadingHTTPServer(("127.0.0.1", 18931), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
