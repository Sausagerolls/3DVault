"""A fake Bambu Lab printer in LAN mode, for testing the Bambu driver without hardware.

It speaks the same protocols as a real A1 mini: MQTT over TLS on 8883 (through a local amqtt
broker), implicit-TLS FTPS (on 9990 here, 990 on a real printer) and the JPEG camera stream on 6000. Prints run for
--seconds and report P1/A1-style partial updates. Development only: needs `pip install amqtt pyftpdlib pyopenssl`.

    python tests/fake_bambu.py --serial 0300AA000000001 --code 12345678 --seconds 60
"""

import argparse
import asyncio
import io
import json
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import zipfile
from pathlib import Path

import paho.mqtt.client as mqtt

HOST = "127.0.0.1"
# Real printers use 990; ports below 1024 need root on most systems, so the fake uses 9990.
FTP_PORT = 9990


def make_cert(d: Path) -> tuple[Path, Path]:
    cert, key = d / "cert.pem", d / "key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=fake-bambu",
         "-keyout", str(key), "-out", str(cert)],
        check=True, capture_output=True,
    )
    return cert, key


def run_broker(cert: Path, key: Path, ready: threading.Event) -> None:
    from amqtt.broker import Broker

    async def main():
        broker = Broker({
            "listeners": {"default": {"type": "tcp", "bind": f"{HOST}:8883", "ssl": True,
                                      "certfile": str(cert), "keyfile": str(key)}},
            "plugins": {"amqtt.plugins.authentication.AnonymousAuthPlugin": {"allow_anonymous": True}},
        })
        await broker.start()
        ready.set()
        await asyncio.Event().wait()

    asyncio.run(main())


def run_ftps(root: Path, code: str, cert: Path, key: Path) -> None:
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import TLS_FTPHandler
    from pyftpdlib.servers import FTPServer

    class Implicit(TLS_FTPHandler):
        def handle(self):
            # Implicit TLS: secure the control connection before the banner.
            self.secure_connection(self.ssl_context)

        def handle_ssl_established(self):
            TLS_FTPHandler.handle(self)

    auth = DummyAuthorizer()
    auth.add_user("bblp", code, str(root), perm="elradfmw")
    Implicit.authorizer = auth
    Implicit.certfile, Implicit.keyfile = str(cert), str(key)
    Implicit.tls_data_required = True
    Implicit.passive_ports = range(50000, 50100)
    FTPServer((HOST, FTP_PORT), Implicit).serve_forever()


def run_camera(code: str, cert: Path, key: Path, printer: "FakePrinter") -> None:
    from PIL import Image, ImageDraw

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv = socket.create_server((HOST, 6000))

    def client(conn):
        try:
            with ctx.wrap_socket(conn, server_side=True) as s:
                auth = s.recv(80)
                if len(auth) < 80 or auth[48:80].rstrip(b"\0").decode() != code:
                    return
                while True:
                    im = Image.new("RGB", (320, 180), (20, 20, 20))
                    ImageDraw.Draw(im).text((10, 10), f"fake A1 mini {printer.state['gcode_state']} {printer.state['mc_percent']}%", fill="white")
                    buf = io.BytesIO()
                    im.save(buf, "JPEG")
                    data = buf.getvalue()
                    s.sendall(struct.pack("<IIII", len(data), 0, 1, 0) + data)
                    time.sleep(0.5)
        except OSError:
            pass

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=client, args=(conn,), daemon=True).start()


class FakePrinter:
    def __init__(self, serial: str, root: Path, seconds: float):
        self.serial, self.root, self.seconds = serial, root, seconds
        self.state = {
            "gcode_state": "IDLE", "mc_percent": 0, "mc_remaining_time": 0, "layer_num": 0, "total_layer_num": 0,
            "nozzle_temper": 24.0, "nozzle_target_temper": 0, "bed_temper": 23.0, "bed_target_temper": 0,
            "subtask_name": "", "gcode_file": "", "print_error": 0,
            "ams": {"ams": [{"id": "0", "tray": [
                {"id": "0", "tray_type": "PLA", "tray_color": "FFFFFFFF", "remain": 90},
                {"id": "1", "tray_type": "PLA", "tray_color": "000000FF", "remain": 40},
                {"id": "2", "tray_type": "PETG", "tray_color": "FF0000FF", "remain": 70},
                {"id": "3"},
            ]}]},
        }
        self.last_command: dict | None = None
        self.started = 0.0
        self.paused_for = 0.0
        self.paused_at = 0.0
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="fake-printer")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        self.client.tls_set_context(ctx)
        self.client.on_message = self.on_message
        self.client.connect(HOST, 8883)
        self.client.subscribe(f"device/{serial}/request")
        self.client.loop_start()

    def report(self, fields: dict) -> None:
        self.client.publish(f"device/{self.serial}/report", json.dumps({"print": {**fields, "command": "push_status"}}))

    def on_message(self, client, userdata, msg):
        data = json.loads(msg.payload)
        if data.get("pushing", {}).get("command") == "pushall":
            self.report(self.state)
            return
        cmd = data.get("print", {})
        self.last_command = cmd
        print("command:", json.dumps(cmd), flush=True)
        c = cmd.get("command")
        if c == "project_file":
            name = cmd["url"].removeprefix("file:///sdcard/")
            path = self.root / name
            plate = cmd["param"]
            ok = path.exists() and plate in zipfile.ZipFile(path).namelist()
            if not ok:
                self.update(gcode_state="FAILED", print_error=0x0500C010)
                return
            self.started, self.paused_for = time.monotonic(), 0.0
            self.update(gcode_state="PREPARE", subtask_name=cmd["subtask_name"], gcode_file=name, mc_percent=0,
                        print_error=0, nozzle_target_temper=220, bed_target_temper=65, total_layer_num=50)
        elif c == "pause" and self.state["gcode_state"] == "RUNNING":
            self.paused_at = time.monotonic()
            self.update(gcode_state="PAUSE")
        elif c == "resume" and self.state["gcode_state"] == "PAUSE":
            self.paused_for += time.monotonic() - self.paused_at
            self.update(gcode_state="RUNNING")
        elif c == "stop":
            self.update(gcode_state="IDLE", nozzle_target_temper=0, bed_target_temper=0)

    def update(self, **fields) -> None:
        """Apply changes and send only the fields that changed, like P1 and A1 firmware."""
        delta = {k: v for k, v in fields.items() if self.state.get(k) != v}
        self.state.update(fields)
        if delta:
            self.report(delta)

    def tick(self) -> None:
        st = self.state["gcode_state"]
        if st not in ("PREPARE", "RUNNING"):
            return
        e = time.monotonic() - self.started - self.paused_for
        if st == "PREPARE":
            self.update(nozzle_temper=min(220.0, 24 + e * 50), bed_temper=min(65.0, 23 + e * 15))
            if e > 4:
                self.update(gcode_state="RUNNING")
            return
        frac = min(1.0, (e - 4) / self.seconds)
        self.update(mc_percent=int(frac * 100), layer_num=max(1, int(frac * 50)),
                    mc_remaining_time=int(self.seconds * (1 - frac) / 60))
        if frac >= 1:
            self.update(gcode_state="FINISH", nozzle_target_temper=0, bed_target_temper=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", default="0300AA000000001")
    ap.add_argument("--code", default="12345678")
    ap.add_argument("--seconds", type=float, default=60)
    args = ap.parse_args()
    d = Path(tempfile.mkdtemp(prefix="fake-bambu-"))
    root = d / "sdcard"
    root.mkdir()
    cert, key = make_cert(d)
    ready = threading.Event()
    threading.Thread(target=run_broker, args=(cert, key, ready), daemon=True).start()
    ready.wait(10)
    threading.Thread(target=run_ftps, args=(root, args.code, cert, key), daemon=True).start()
    printer = FakePrinter(args.serial, root, args.seconds)
    threading.Thread(target=run_camera, args=(args.code, cert, key, printer), daemon=True).start()
    print(f"fake Bambu printer {args.serial} on {HOST}, sdcard at {root}", flush=True)
    while True:
        printer.tick()
        time.sleep(1)


if __name__ == "__main__":
    main()
