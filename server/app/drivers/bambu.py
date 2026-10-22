"""Bambu Lab printers in LAN mode.

The printer must be in LAN Only mode with Developer Mode switched on. It then accepts:
- MQTT over TLS on port 8883 (user "bblp", password = LAN access code). Reports arrive on
  device/<serial>/report and commands go to device/<serial>/request. P1 and A1 printers only
  send the fields that changed, so reports are merged into one state dict.
- FTPS with implicit TLS on port 990 for uploading the sliced .gcode.3mf.
- A1 and P1 cameras: a TLS socket on port 6000 sending JPEG frames. X1 and H2 cameras use
  RTSPS, which isn't supported yet.
The printers use self-signed certificates, so certificate checks are off for the LAN connection.
"""

import ftplib
import json
import logging
import socket
import ssl
import struct
import threading
import time

from .base import AmsSlot, Driver, DriverError, PrintRequest, Status, Temp

log = logging.getLogger("vault.bambu")

MQTT_PORT = 8883
FTP_PORT = 990
CAMERA_PORT = 6000
PUSHALL_SECONDS = 300

GCODE_STATES = {
    "IDLE": "idle",
    "PREPARE": "preparing",
    "SLICING": "preparing",
    "RUNNING": "printing",
    "PAUSE": "paused",
    "FINISH": "finished",
    "FAILED": "failed",
}

# Serial number prefixes and SSDP model codes. Only the camera transport depends on the model.
SERIAL_MODELS = {
    "030": "A1 mini", "039": "A1", "01S": "P1P", "01P": "P1S", "22E": "P2S",
    "00M": "X1 Carbon", "03W": "X1E", "094": "H2D", "239": "H2S",
}
MODEL_CODES = {
    "N1": "A1 mini", "N2S": "A1", "C11": "P1P", "C12": "P1S", "N7": "P2S",
    "BL-P001": "X1 Carbon", "BL-P002": "X1", "C13": "X1E", "O1D": "H2D", "O1S": "H2S",
}
RTSP_MODELS = {"X1 Carbon", "X1", "X1E", "H2D", "H2S"}


def model_name(serial: str) -> str:
    return SERIAL_MODELS.get(serial[:3], "")


def _insecure_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def merge(into: dict, update: dict) -> None:
    """Merge a partial report into the full state. Lists are replaced, dicts merged."""
    for k, v in update.items():
        if isinstance(v, dict) and isinstance(into.get(k), dict):
            merge(into[k], v)
        else:
            into[k] = v


def parse_status(p: dict) -> Status:
    """Turn the merged "print" report into a Status."""
    s = Status(state=GCODE_STATES.get(str(p.get("gcode_state", "")).upper(), "idle"))
    s.progress = float(p.get("mc_percent") or 0)
    s.layer = p.get("layer_num")
    s.total_layers = p.get("total_layer_num")
    if p.get("mc_remaining_time") is not None:
        s.remaining_s = int(p["mc_remaining_time"]) * 60
    s.file = p.get("subtask_name") or p.get("gcode_file") or ""
    s.nozzle = Temp(p.get("nozzle_temper"), p.get("nozzle_target_temper"))
    s.bed = Temp(p.get("bed_temper"), p.get("bed_target_temper"))
    for unit in (p.get("ams") or {}).get("ams") or []:
        for tray in unit.get("tray") or []:
            if not tray.get("tray_type"):
                continue  # empty slot
            remain = tray.get("remain")
            s.ams.append(AmsSlot(
                unit=int(unit.get("id", 0)),
                slot=int(tray.get("id", 0)),
                type=tray.get("tray_type", ""),
                color="#" + str(tray.get("tray_color", ""))[:6] if tray.get("tray_color") else "",
                remaining=remain if isinstance(remain, int) and remain >= 0 else None,
            ))
    err = p.get("print_error") or 0
    if s.state == "failed" and err:
        s.message = f"Printer error {int(err):08X}. Check the printer screen."
    return s


def project_file_command(req: PrintRequest) -> dict:
    """The MQTT command that starts printing an uploaded .gcode.3mf."""
    use_ams = any(i >= 0 for i in req.ams_mapping)
    o = req.options
    cmd = {
        "sequence_id": str(int(time.time())),
        "command": "project_file",
        "param": f"Metadata/plate_{req.plate}.gcode",
        "project_id": "0",
        "profile_id": "0",
        "task_id": "0",
        "subtask_id": "0",
        "subtask_name": req.remote_name.removesuffix(".3mf").removesuffix(".gcode"),
        "url": f"file:///sdcard/{req.remote_name}",
        "md5": "",
        "timelapse": bool(o.get("timelapse", False)),
        "bed_type": "auto",
        "bed_levelling": bool(o.get("bed_levelling", True)),
        "flow_cali": bool(o.get("flow_cali", False)),
        "vibration_cali": bool(o.get("vibration_cali", False)),
        "layer_inspect": False,
        "use_ams": use_ams,
    }
    if use_ams:
        cmd["ams_mapping"] = req.ams_mapping
    return {"print": cmd}


class ImplicitFTPS(ftplib.FTP_TLS):
    """FTP over implicit TLS as Bambu printers expect: TLS from the first byte, and data
    connections reusing the control connection's TLS session."""

    def connect(self, host="", port=FTP_PORT, timeout=30, source_address=None):
        self.host, self.port, self.timeout = host, port, timeout
        sock = socket.create_connection((host, port), timeout)
        self.af = sock.family
        self.sock = self.context.wrap_socket(sock, server_hostname=host)
        self.file = self.sock.makefile("r", encoding=self.encoding)
        self.welcome = self.getresp()
        return self.welcome

    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(conn, server_hostname=self.host, session=self.sock.session)
        return conn, size

    def storbinary(self, cmd, fp, blocksize=1024 * 1024, callback=None, rest=None):
        # The stock version calls unwrap() on the data socket, which Bambu printers never answer.
        self.voidcmd("TYPE I")
        with self.transfercmd(cmd, rest) as conn:
            while buf := fp.read(blocksize):
                conn.sendall(buf)
                if callback:
                    callback(buf)
        return self.voidresp()


class BambuDriver(Driver):
    kind = "bambu"
    label = "Bambu Lab (LAN mode)"
    formats = {"gcode3mf"}
    has_camera = True
    fields = [("host", "IP address", False), ("serial", "Serial number", False), ("secret", "LAN access code", True)]

    def __init__(self, config):
        super().__init__(config)
        self._lock = threading.Lock()
        self._state: dict = {}
        self._client = None
        self._connected = False
        self._error = ""
        self._last_pushall = 0.0

    # ---------------------------------------------------------------- MQTT

    def _make_client(self):
        import paho.mqtt.client as mqtt

        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"3dvault-{self.config.id}-{int(time.time())}")
        c.tls_set_context(_insecure_context())
        c.tls_insecure_set(True)
        c.username_pw_set("bblp", self.config.secret)
        c.reconnect_delay_set(2, 60)
        return c

    def start(self) -> None:
        if not (self.config.host and self.config.serial and self.config.secret):
            self._error = "Missing IP address, serial number or access code"
            return
        c = self._make_client()
        c.on_connect = self._on_connect
        c.on_disconnect = self._on_disconnect
        c.on_message = self._on_message
        self._client = c
        c.connect_async(self.config.host, MQTT_PORT, keepalive=30)
        c.loop_start()

    def stop(self) -> None:
        if self._client:
            self._client.loop_stop()
            self._client.disconnect()

    def _on_connect(self, client, userdata, flags, reason, properties=None):
        if getattr(reason, "is_failure", False):
            self._connected = False
            self._error = "Access code refused" if "authori" in str(reason).lower() or "password" in str(reason).lower() else str(reason)
            return
        self._connected, self._error = True, ""
        client.subscribe(f"device/{self.config.serial}/report")
        self._pushall()

    def _on_disconnect(self, client, userdata, flags, reason, properties=None):
        self._connected = False
        if not self._error:
            self._error = "Disconnected"

    def _on_message(self, client, userdata, msg):
        try:
            data = json.loads(msg.payload)
        except ValueError:
            return
        with self._lock:
            merge(self._state, data)

    def _publish(self, payload: dict) -> None:
        if not (self._client and self._connected):
            raise DriverError("Printer is not connected")
        info = self._client.publish(f"device/{self.config.serial}/request", json.dumps(payload))
        if info.rc != 0:
            raise DriverError("Couldn't send the command to the printer")

    def _pushall(self) -> None:
        self._last_pushall = time.monotonic()
        try:
            self._publish({"pushing": {"sequence_id": "0", "command": "pushall", "version": 1, "push_target": 1}})
        except DriverError:
            pass

    # ---------------------------------------------------------------- driver

    def status(self) -> Status:
        if not self._connected:
            return Status(state="offline", message=self._error or "Connecting…")
        if time.monotonic() - self._last_pushall > PUSHALL_SECONDS:
            self._pushall()
        with self._lock:
            p = json.loads(json.dumps(self._state.get("print") or {}))
        if not p:
            return Status(state="offline", message="Waiting for the printer to report")
        return parse_status(p)

    def send(self, req: PrintRequest) -> None:
        if not req.remote_name.endswith(".3mf"):
            raise DriverError("Bambu printers need a sliced .gcode.3mf file")
        if self.status().state in ("preparing", "printing", "paused"):
            raise DriverError("Printer is busy")
        self.upload(req)
        self._publish(project_file_command(req))

    def upload(self, req: PrintRequest) -> None:
        try:
            ftp = ImplicitFTPS(context=_insecure_context(), timeout=60)
            ftp.connect(self.config.host, FTP_PORT)
            ftp.login("bblp", self.config.secret)
            ftp.prot_p()
            with open(req.path, "rb") as fp:
                ftp.storbinary(f"STOR {req.remote_name}", fp)
            try:
                ftp.quit()
            except Exception:
                ftp.close()
        except ftplib.error_perm as e:
            raise DriverError(f"Printer refused the upload: {e}. Is there an SD card in the printer?")
        except (OSError, ftplib.Error) as e:
            raise DriverError(f"Upload to the printer failed: {e}")

    def pause(self) -> None:
        self._publish({"print": {"sequence_id": "0", "command": "pause", "param": ""}})

    def resume(self) -> None:
        self._publish({"print": {"sequence_id": "0", "command": "resume", "param": ""}})

    def cancel(self) -> None:
        self._publish({"print": {"sequence_id": "0", "command": "stop", "param": ""}})

    def snapshot(self) -> bytes | None:
        if model_name(self.config.serial) in RTSP_MODELS:
            return None
        return camera_frame(self.config.host, self.config.secret)


def camera_frame(host: str, access_code: str, timeout: float = 8) -> bytes | None:
    """Read one JPEG from the A1/P1 camera stream on port 6000."""
    auth = struct.pack("<IIII", 0x40, 0x3000, 0, 0) + b"bblp".ljust(32, b"\0") + access_code.encode().ljust(32, b"\0")
    try:
        with socket.create_connection((host, CAMERA_PORT), timeout) as raw:
            with _insecure_context().wrap_socket(raw, server_hostname=host) as s:
                s.sendall(auth)
                header = _read_exact(s, 16)
                size = struct.unpack("<I", header[:4])[0]
                if not 0 < size < 10_000_000:
                    return None
                data = _read_exact(s, size)
    except OSError:
        return None
    return data if data.startswith(b"\xff\xd8") else None


def _read_exact(s, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise OSError("camera stream closed")
        buf += chunk
    return buf


# ---------------------------------------------------------------- discovery


def discover(seconds: float = 6.0) -> list[dict]:
    """Find Bambu printers on the LAN from their SSDP announcements.

    Printers announce themselves on UDP 2021 every few seconds and answer an M-SEARCH on 1990.
    Needs the container on the host network; Docker's bridge network doesn't pass broadcasts.
    """
    found: dict[str, dict] = {}
    socks = []
    for port in (2021, 1990):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            s.bind(("", port))
            try:
                mreq = struct.pack("4sl", socket.inet_aton("239.255.255.250"), socket.INADDR_ANY)
                s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            except OSError:
                pass
            s.settimeout(0.5)
            socks.append(s)
        except OSError as e:
            log.info("can't listen on UDP %s: %s", port, e)
    try:
        search = (
            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\n"
            "MX: 3\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
        ).encode()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as out:
            out.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for target in (("239.255.255.250", 1990), ("255.255.255.255", 1990), ("255.255.255.255", 2021)):
                try:
                    out.sendto(search, target)
                except OSError:
                    pass
        end = time.monotonic() + seconds
        while time.monotonic() < end and socks:
            for s in socks:
                try:
                    data, addr = s.recvfrom(4096)
                except (socket.timeout, OSError):
                    continue
                p = parse_ssdp(data.decode(errors="replace"), addr[0])
                if p:
                    found[p["serial"]] = p
    finally:
        for s in socks:
            s.close()
    return list(found.values())


def parse_ssdp(text: str, sender: str) -> dict | None:
    headers = {}
    for line in text.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    if "bambu" not in text.lower() or not headers.get("usn"):
        return None
    code = headers.get("devmodel.bambu.com", "")
    return {
        "kind": "bambu",
        "serial": headers["usn"],
        "host": headers.get("location") or sender,
        "name": headers.get("devname.bambu.com") or headers["usn"],
        "model": MODEL_CODES.get(code, code),
        "lan_mode": headers.get("devconnect.bambu.com", "").lower() == "lan",
    }
