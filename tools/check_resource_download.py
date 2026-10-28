#!/usr/bin/env python3
"""Exercise production Swift resource transport against a local bounded fixture."""
from pathlib import Path
import http.server
import json
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Sources/PaywallKit'

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    ports = set()
    requests = 0
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def do_GET(self):
        try:
            self.reply()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Intentional client cancellation and deadline expiry.

    def reply(self):
        if self.path == '/delayed':
            time.sleep(0.15)
            body = b'A' * 4096
        elif self.path == '/bytes':
            with self.lock:
                type(self).requests += 1
                self.ports.add(self.client_address[1])
            body = b'A' * 4096
        elif self.path == '/stats':
            with self.lock:
                body = json.dumps({'byteRequests': self.requests, 'byteConnections': len(self.ports)}).encode()
        elif self.path in ['/chunked', '/chunked-too-large', '/stall']:
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            if self.path == '/stall':
                time.sleep(1.5)
            chunks = [b'1234', b'5678'] if self.path != '/chunked-too-large' else [b'12345678'] * 2
            for chunk in chunks:
                self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
                self.wfile.flush()
            self.wfile.write(b'0\r\n\r\n')
            return
        else:
            body = b'' if self.path == '/empty' else b'x' * 50
        status = 302 if self.path == '/redirect' else 503 if self.path == '/status' else 200
        self.send_response(status)
        if status == 302:
            self.send_header('Location', '/bytes')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with tempfile.TemporaryDirectory(prefix='paywall-download-check-') as temp:
    binary = str(Path(temp) / 'check')
    sources = [
        'modules/WebPaywall/ResourcesCache/WebPaywallResourceDownload.swift',
        'modules/WebPaywall/ResourcesCache/WebPaywallDownloadDelegate.swift',
        'modules/WebPaywall/ResourcesCache/WebPaywallDownloadCancellation.swift',
        'modules/PaywallClient/Query/PaywallQueryRetry.swift',
        'modules/WebPaywall/WebPaywallDiagnostics.swift',
        'modules/WebPaywall/PaywallLogging.swift',
    'modules/WebPaywall/PaywallLogStore.swift',
    ]
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(temp) / 'modules'),
                    *[str(BASE / p) for p in sources], str(ROOT / 'tools/check_resource_download.swift'),
                    '-o', binary], check=True)
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            subprocess.run([binary, f'http://127.0.0.1:{server.server_port}'], check=True, timeout=20)
        finally:
            server.shutdown()
