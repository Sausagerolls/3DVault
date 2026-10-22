"""Fake Moonraker, PrusaLink and OctoPrint printers for testing the HTTP drivers.

    python tests/fake_http_printers.py --seconds 20

Moonraker on 127.0.0.1:7125, PrusaLink on :8081 (digest user "maker", password "secret"),
OctoPrint on :5000 (API key "secret"). Each prints an uploaded file for --seconds.
"""

import argparse
import hashlib
import io
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECONDS = 20.0


class Job:
    def __init__(self):
        self.lock = threading.Lock()
        self.file = ""
        self.state = "idle"  # idle | printing | paused | finished | cancelled
        self.started = 0.0
        self.paused_for = 0.0
        self.paused_at = 0.0

    def start(self, name):
        with self.lock:
            self.file, self.state, self.started, self.paused_for = name, "printing", time.monotonic(), 0.0

    def progress(self) -> float:
        with self.lock:
            if self.state in ("idle", "cancelled"):
                return 0.0
            if self.state == "finished":
                return 1.0
            now = self.paused_at if self.state == "paused" else time.monotonic()
            p = min(1.0, (now - self.started - self.paused_for) / SECONDS)
            if p >= 1:
                self.state = "finished"
            return p

    def pause(self):
        with self.lock:
            if self.state == "printing":
                self.state, self.paused_at = "paused", time.monotonic()

    def resume(self):
        with self.lock:
            if self.state == "paused":
                self.paused_for += time.monotonic() - self.paused_at
                self.state = "printing"

    def cancel(self):
        with self.lock:
            self.state = "cancelled"


def jpeg() -> bytes:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (40, 80, 120)).save(buf, "JPEG")
    return buf.getvalue()


class Base(BaseHTTPRequestHandler):
    job: Job

    def log_message(self, *a):
        pass

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self) -> bytes:
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def multipart_filename(self, raw: bytes) -> str:
        head = raw[:2000].decode(errors="replace")
        i = head.find('filename="')
        return head[i + 10: head.find('"', i + 10)] if i >= 0 else "upload.gcode"


class Moonraker(Base):
    job = Job()

    def do_GET(self):
        p = self.job.progress()
        if self.path == "/printer/info":
            return self.send_json({"result": {"state": "ready"}})
        if self.path.startswith("/printer/objects/query"):
            st = {"idle": "standby", "printing": "printing", "paused": "paused", "finished": "complete", "cancelled": "cancelled"}[self.job.state]
            return self.send_json({"result": {"status": {
                "print_stats": {"state": st, "filename": self.job.file, "print_duration": p * SECONDS, "info": {"current_layer": int(p * 40), "total_layer": 40}},
                "virtual_sdcard": {"progress": p}, "display_status": {"progress": p},
                "extruder": {"temperature": 215.0, "target": 215.0}, "heater_bed": {"temperature": 60.0, "target": 60.0}}}})
        if self.path == "/server/webcams/list":
            return self.send_json({"result": {"webcams": [{"enabled": True, "snapshot_url": "http://127.0.0.1:7125/snap.jpg"}]}})
        if self.path == "/snap.jpg":
            data = jpeg()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        self.send_json({"error": {"message": "not found"}}, 404)

    def do_POST(self):
        raw = self.body()
        if self.path == "/server/files/upload":
            self.job.start(self.multipart_filename(raw))
            return self.send_json({"result": {"item": {"path": "x"}, "print_started": True}}, 201)
        action = {"/printer/print/pause": self.job.pause, "/printer/print/resume": self.job.resume, "/printer/print/cancel": self.job.cancel}.get(self.path)
        if action:
            action()
            return self.send_json({"result": "ok"})
        self.send_json({"error": {"message": "not found"}}, 404)


class PrusaLink(Base):
    job = Job()
    realm, nonce = "Printer API", "abc123"

    def authed(self) -> bool:
        h = self.headers.get("Authorization", "")
        if not h.startswith("Digest "):
            self.send_response(401)
            self.send_header("WWW-Authenticate", f'Digest realm="{self.realm}", nonce="{self.nonce}", algorithm=MD5')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        parts = dict(p.strip().split("=", 1) for p in h[7:].split(","))
        parts = {k: v.strip('"') for k, v in parts.items()}
        ha1 = hashlib.md5(f"maker:{self.realm}:secret".encode()).hexdigest()
        ha2 = hashlib.md5(f"{self.command}:{parts['uri']}".encode()).hexdigest()
        if "qop" in parts:
            expect = hashlib.md5(f"{ha1}:{self.nonce}:{parts['nc']}:{parts['cnonce']}:{parts['qop']}:{ha2}".encode()).hexdigest()
        else:
            expect = hashlib.md5(f"{ha1}:{self.nonce}:{ha2}".encode()).hexdigest()
        if parts.get("response") != expect:
            self.send_json({"title": "Unauthorized"}, 401)
            return False
        return True

    def do_GET(self):
        if not self.authed():
            return
        p = self.job.progress()
        if self.path == "/api/v1/status":
            st = {"idle": "IDLE", "printing": "PRINTING", "paused": "PAUSED", "finished": "FINISHED", "cancelled": "STOPPED"}[self.job.state]
            job = {"id": 7, "progress": round(p * 100, 1), "time_remaining": int(SECONDS * (1 - p))} if self.job.state != "idle" else None
            return self.send_json({"printer": {"state": st, "temp_nozzle": 215, "target_nozzle": 215, "temp_bed": 60, "target_bed": 60}, "job": job})
        if self.path == "/api/v1/storage":
            return self.send_json({"storage_list": [{"path": "/usb", "available": True, "read_only": False}]})
        if self.path == "/api/v1/job":
            return self.send_json({"id": 7} if self.job.state in ("printing", "paused") else {})
        self.send_json({"title": "not found"}, 404)

    def do_PUT(self):
        if not self.authed():
            return
        raw = self.body()
        if self.path.startswith("/api/v1/files/usb/"):
            if self.headers.get("Print-After-Upload") == "?1":
                self.job.start(self.path.rsplit("/", 1)[-1])
            self.send_response(201)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/api/v1/job/7/pause":
            self.job.pause()
        elif self.path == "/api/v1/job/7/resume":
            self.job.resume()
        self.send_response(204)
        self.end_headers()

    def do_DELETE(self):
        if not self.authed():
            return
        self.job.cancel()
        self.send_response(204)
        self.end_headers()


class OctoPrint(Base):
    job = Job()

    def authed(self):
        if self.headers.get("X-Api-Key") != "secret":
            self.send_json({"error": "Invalid API key"}, 403)
            return False
        return True

    def do_GET(self):
        if not self.authed():
            return
        p = self.job.progress()
        s = self.job.state
        if self.path == "/api/printer":
            flags = {"operational": True, "printing": s == "printing", "paused": s == "paused", "error": False, "ready": s != "printing"}
            return self.send_json({"state": {"text": s, "flags": flags}, "temperature": {"tool0": {"actual": 210.0, "target": 210.0}, "bed": {"actual": 60.0, "target": 60.0}}})
        if self.path == "/api/job":
            done = 100.0 if s == "finished" else (round(p * 100, 1) if s in ("printing", "paused") else None)
            return self.send_json({"job": {"file": {"name": self.job.file}}, "progress": {"completion": done, "printTimeLeft": int(SECONDS * (1 - p))}, "state": s})
        if self.path == "/api/settings":
            return self.send_json({"webcam": {"snapshotUrl": "/webcam/?action=snapshot"}})
        if self.path.startswith("/webcam/"):
            data = jpeg()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if not self.authed():
            return
        raw = self.body()
        if self.path == "/api/files/local":
            self.job.start(self.multipart_filename(raw))
            return self.send_json({"done": True}, 201)
        if self.path == "/api/job":
            cmd = json.loads(raw)
            if cmd["command"] == "cancel":
                self.job.cancel()
            elif cmd.get("action") == "pause":
                self.job.pause()
            elif cmd.get("action") == "resume":
                self.job.resume()
            self.send_response(204)
            self.end_headers()
            return
        self.send_json({"error": "not found"}, 404)


def main():
    global SECONDS
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20)
    SECONDS = ap.parse_args().seconds
    for handler, port in ((Moonraker, 7125), (PrusaLink, 8081), (OctoPrint, 5000)):
        threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever, daemon=True).start()
    print("fake Moonraker :7125, PrusaLink :8081, OctoPrint :5000", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
