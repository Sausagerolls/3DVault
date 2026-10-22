"""Printers with a local HTTP API: Klipper (Moonraker), Prusa (PrusaLink) and OctoPrint."""

import threading
import time

import httpx

from .base import Driver, DriverError, PrintRequest, Status, Temp


def base_url(host: str, default_port: int | None = None) -> str:
    host = host.strip().rstrip("/")
    if not host:
        return ""
    if "://" not in host:
        host = f"http://{host}"
        if default_port and host.count(":") == 1:
            host += f":{default_port}"
    return host


class HttpDriver(Driver):
    """Common plumbing: one httpx client per printer, errors turned into DriverError."""

    default_port: int | None = None

    def __init__(self, config):
        super().__init__(config)
        self.url = base_url(config.host, self.default_port)
        self._client: httpx.Client | None = None
        self._lock = threading.Lock()

    def headers(self) -> dict:
        return {"X-Api-Key": self.config.secret} if self.config.secret else {}

    def auth(self):
        return None

    def client(self) -> httpx.Client:
        with self._lock:
            if self._client is None:
                self._client = httpx.Client(base_url=self.url, headers=self.headers(), auth=self.auth(), timeout=10)
            return self._client

    def stop(self) -> None:
        if self._client:
            self._client.close()

    def request(self, method: str, path: str, timeout: float | None = None, **kw) -> httpx.Response:
        if not self.url:
            raise DriverError("No address set for this printer")
        try:
            r = self.client().request(method, path, timeout=timeout or 10, **kw)
        except httpx.TimeoutException:
            raise DriverError("The printer didn't answer")
        except httpx.HTTPError as e:
            raise DriverError(f"Can't reach the printer: {e}")
        if r.status_code in (401, 403):
            raise DriverError("The printer refused the API key or password")
        return r

    def json(self, method: str, path: str, **kw) -> dict:
        r = self.request(method, path, **kw)
        if r.status_code >= 400:
            raise DriverError(_detail(r))
        return r.json() if r.content else {}

    def status(self) -> Status:
        try:
            return self.read_status()
        except DriverError as e:
            return Status(state="offline", message=str(e))

    def read_status(self) -> Status:
        raise NotImplementedError

    def snapshot(self) -> bytes | None:
        url = self.snapshot_url()
        if not url:
            return None
        try:
            r = self.client().get(url, timeout=8)
        except httpx.HTTPError:
            return None
        return r.content if r.status_code == 200 and r.content[:2] == b"\xff\xd8" else None

    def snapshot_url(self) -> str | None:
        return None


def _detail(r: httpx.Response) -> str:
    try:
        data = r.json()
        msg = data.get("error", {}).get("message") if isinstance(data.get("error"), dict) else data.get("error") or data.get("title") or data.get("message")
    except ValueError:
        msg = r.text[:200]
    return f"The printer said: {msg or r.reason_phrase} ({r.status_code})"


# ---------------------------------------------------------------- Klipper


class MoonrakerDriver(HttpDriver):
    kind = "moonraker"
    label = "Klipper (Moonraker)"
    formats = {"gcode"}
    has_camera = True
    default_port = 7125
    fields = [("host", "Address (IP or name, port 7125 by default)", False), ("secret", "API key (if Moonraker requires one)", True)]

    STATES = {"standby": "idle", "printing": "printing", "paused": "paused", "complete": "finished", "cancelled": "idle", "error": "failed"}

    def read_status(self) -> Status:
        info = self.json("GET", "/printer/info").get("result", {})
        if info.get("state") != "ready":
            return Status(state="offline", message=info.get("state_message") or f"Klipper is {info.get('state', 'not ready')}")
        q = "print_stats&virtual_sdcard&extruder&heater_bed&display_status"
        st = self.json("GET", f"/printer/objects/query?{q}").get("result", {}).get("status", {})
        ps = st.get("print_stats", {})
        s = Status(state=self.STATES.get(ps.get("state", ""), "idle"), file=ps.get("filename", ""))
        progress = st.get("display_status", {}).get("progress") or st.get("virtual_sdcard", {}).get("progress") or 0
        s.progress = round(float(progress) * 100, 1)
        layer_info = ps.get("info") or {}
        s.layer, s.total_layers = layer_info.get("current_layer"), layer_info.get("total_layer")
        elapsed = ps.get("print_duration") or 0
        if s.state in ("printing", "paused") and progress > 0.01:
            s.remaining_s = int(elapsed / progress - elapsed)
        ex, bed = st.get("extruder", {}), st.get("heater_bed", {})
        s.nozzle = Temp(ex.get("temperature"), ex.get("target"))
        s.bed = Temp(bed.get("temperature"), bed.get("target"))
        if s.state == "failed":
            s.message = ps.get("message") or "Klipper reported an error"
        return s

    def send(self, req: PrintRequest) -> None:
        with open(req.path, "rb") as fp:
            r = self.request("POST", "/server/files/upload", timeout=600,
                             files={"file": (req.remote_name, fp, "application/octet-stream")},
                             data={"root": "gcodes", "print": "true"})
        if r.status_code >= 400:
            raise DriverError(_detail(r))

    def pause(self) -> None:
        self.json("POST", "/printer/print/pause")

    def resume(self) -> None:
        self.json("POST", "/printer/print/resume")

    def cancel(self) -> None:
        self.json("POST", "/printer/print/cancel")

    def snapshot_url(self) -> str | None:
        try:
            cams = self.json("GET", "/server/webcams/list").get("result", {}).get("webcams", [])
        except DriverError:
            return None
        cam = next((c for c in cams if c.get("enabled", True) and c.get("snapshot_url")), None)
        if not cam:
            return None
        url = cam["snapshot_url"]
        if "://" in url:
            return url
        # Relative webcam URLs are served by the web server in front of Moonraker, not port 7125.
        return str(httpx.URL(self.url).copy_with(port=None, path="/")).rstrip("/") + url


# ---------------------------------------------------------------- Prusa


class PrusaLinkDriver(HttpDriver):
    kind = "prusalink"
    label = "Prusa (PrusaLink)"
    formats = {"gcode", "bgcode"}
    fields = [("host", "IP address", False), ("secret", "PrusaLink password or API key", True)]

    STATES = {
        "IDLE": "idle", "READY": "idle", "BUSY": "preparing", "PRINTING": "printing", "PAUSED": "paused",
        "FINISHED": "finished", "STOPPED": "idle", "ERROR": "failed", "ATTENTION": "paused",
    }

    def headers(self) -> dict:
        return {}

    def auth(self):
        # Current firmware uses digest auth for the "maker" user; older firmware an API key header.
        return httpx.DigestAuth("maker", self.config.secret) if self.config.secret else None

    def read_status(self) -> Status:
        r = self.request("GET", "/api/v1/status")
        if r.status_code in (401, 403) or r.status_code >= 400:
            raise DriverError(_detail(r))
        data = r.json()
        p, job = data.get("printer", {}), data.get("job") or {}
        raw = str(p.get("state", "")).upper()
        s = Status(state=self.STATES.get(raw, "idle"))
        s.nozzle = Temp(p.get("temp_nozzle"), p.get("target_nozzle"))
        s.bed = Temp(p.get("temp_bed"), p.get("target_bed"))
        if job:
            s.progress = float(job.get("progress") or 0)
            s.remaining_s = job.get("time_remaining")
        if raw == "ATTENTION":
            s.message = "The printer needs attention. Check its screen."
        elif raw == "ERROR":
            s.message = "The printer reported an error"
        return s

    def _storage(self) -> str:
        data = self.json("GET", "/api/v1/storage")
        for st in data.get("storage_list", []):
            if st.get("available") and not st.get("read_only"):
                return st.get("path", "/usb").strip("/")
        return "usb"

    def _job_id(self) -> int:
        job = self.json("GET", "/api/v1/job")
        if not job.get("id"):
            raise DriverError("No print is running")
        return job["id"]

    def send(self, req: PrintRequest) -> None:
        storage = self._storage()
        with open(req.path, "rb") as fp:
            r = self.request("PUT", f"/api/v1/files/{storage}/{req.remote_name}", timeout=600, content=fp.read(),
                             headers={"Content-Type": "application/octet-stream", "Print-After-Upload": "?1", "Overwrite": "?1"})
        if r.status_code >= 400:
            raise DriverError(_detail(r))

    def pause(self) -> None:
        self.request("PUT", f"/api/v1/job/{self._job_id()}/pause")

    def resume(self) -> None:
        self.request("PUT", f"/api/v1/job/{self._job_id()}/resume")

    def cancel(self) -> None:
        self.request("DELETE", f"/api/v1/job/{self._job_id()}")


# ---------------------------------------------------------------- OctoPrint


class OctoPrintDriver(HttpDriver):
    kind = "octoprint"
    label = "OctoPrint"
    formats = {"gcode"}
    has_camera = True
    fields = [("host", "Address (http://octopi.local or an IP)", False), ("secret", "API key", True)]

    def read_status(self) -> Status:
        r = self.request("GET", "/api/printer")
        if r.status_code == 409:
            return Status(state="offline", message="OctoPrint isn't connected to the printer")
        if r.status_code >= 400:
            raise DriverError(_detail(r))
        pr = r.json()
        flags = pr.get("state", {}).get("flags", {})
        job = self.json("GET", "/api/job")
        progress = (job.get("progress") or {}).get("completion") or 0
        if flags.get("error") or flags.get("closedOrError"):
            state = "failed"
        elif flags.get("paused") or flags.get("pausing"):
            state = "paused"
        elif flags.get("printing") or flags.get("cancelling"):
            state = "printing"
        elif progress >= 100:
            state = "finished"
        else:
            state = "idle"
        s = Status(state=state, progress=round(float(progress), 1),
                   file=((job.get("job") or {}).get("file") or {}).get("name") or "")
        s.remaining_s = (job.get("progress") or {}).get("printTimeLeft")
        temps = pr.get("temperature", {})
        t, b = temps.get("tool0", {}), temps.get("bed", {})
        s.nozzle = Temp(t.get("actual"), t.get("target"))
        s.bed = Temp(b.get("actual"), b.get("target"))
        if state == "failed":
            s.message = pr.get("state", {}).get("text") or "OctoPrint reported an error"
        return s

    def send(self, req: PrintRequest) -> None:
        with open(req.path, "rb") as fp:
            r = self.request("POST", "/api/files/local", timeout=600,
                             files={"file": (req.remote_name, fp, "application/octet-stream")},
                             data={"select": "true", "print": "true"})
        if r.status_code >= 400:
            raise DriverError(_detail(r))

    def _job(self, body: dict) -> None:
        r = self.request("POST", "/api/job", json=body)
        if r.status_code >= 400:
            raise DriverError(_detail(r))

    def pause(self) -> None:
        self._job({"command": "pause", "action": "pause"})

    def resume(self) -> None:
        self._job({"command": "pause", "action": "resume"})

    def cancel(self) -> None:
        self._job({"command": "cancel"})

    def snapshot_url(self) -> str | None:
        try:
            url = self.json("GET", "/api/settings").get("webcam", {}).get("snapshotUrl") or ""
        except DriverError:
            return None
        if not url:
            return None
        return url if "://" in url else f"{self.url}{url if url.startswith('/') else '/' + url}"
