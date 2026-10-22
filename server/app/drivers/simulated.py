"""A pretend printer for development, tests and the App Review demo server.

It accepts any pre-sliced file, heats up, prints for VAULT_SIM_PRINT_SECONDS (default 180) and
draws a camera frame showing progress. A file name containing "fail" stops with an error at 40%.
"""

import io
import os
import threading
import time

from .base import AmsSlot, Driver, DriverError, PrintRequest, Status, Temp

PRINT_SECONDS = float(os.environ.get("VAULT_SIM_PRINT_SECONDS", "180"))
HEAT_SECONDS = 8.0
LAYERS = 120


class SimulatedDriver(Driver):
    kind = "simulated"
    label = "Simulated printer"
    formats = {"gcode", "bgcode", "gcode3mf"}
    has_camera = True
    fields = []

    def __init__(self, config):
        super().__init__(config)
        self._lock = threading.Lock()
        self._file = ""
        self._state = "idle"
        self._started = 0.0  # monotonic time printing began, shifted forward by pauses
        self._paused_at = 0.0
        self._fail = False
        self._ended_progress = 0.0

    def _elapsed(self, now: float) -> float:
        return (self._paused_at if self._state == "paused" else now) - self._started

    def _tick(self) -> None:
        now = time.monotonic()
        if self._state in ("preparing", "printing"):
            e = self._elapsed(now)
            if e >= HEAT_SECONDS:
                self._state = "printing"
            frac = max(0.0, (e - HEAT_SECONDS) / PRINT_SECONDS)
            if self._fail and frac >= 0.4:
                self._state, self._ended_progress = "failed", 40.0
            elif frac >= 1:
                self._state, self._ended_progress = "finished", 100.0

    def status(self) -> Status:
        with self._lock:
            self._tick()
            s = Status(state=self._state, file=self._file, ams=[
                AmsSlot(0, 0, "PLA", "#F2F2F2", 80), AmsSlot(0, 1, "PLA", "#1E1E1E", 55),
                AmsSlot(0, 2, "PETG", "#D9302C", 100), AmsSlot(0, 3, "PLA", "#2F6FDE", 20),
            ])
            hot = self._state in ("preparing", "printing", "paused")
            heat = min(1.0, self._elapsed(time.monotonic()) / HEAT_SECONDS) if hot else 0
            s.nozzle = Temp(round(25 + 195 * heat, 1), 220 if hot else 0)
            s.bed = Temp(round(25 + 35 * heat, 1), 60 if hot else 0)
            if self._state in ("printing", "paused"):
                e = self._elapsed(time.monotonic()) - HEAT_SECONDS
                frac = min(1.0, max(0.0, e / PRINT_SECONDS))
                s.progress = round(frac * 100, 1)
                s.total_layers = LAYERS
                s.layer = max(1, int(frac * LAYERS))
                s.remaining_s = int(PRINT_SECONDS * (1 - frac))
            elif self._state in ("finished", "failed"):
                s.progress = self._ended_progress
                s.total_layers = LAYERS
                s.layer = int(self._ended_progress / 100 * LAYERS)
                s.remaining_s = 0
                if self._state == "failed":
                    s.message = "Simulated failure: spaghetti detected"
            return s

    def send(self, req: PrintRequest) -> None:
        if not req.path.exists():
            raise DriverError("File is missing on the server")
        with self._lock:
            self._tick()
            if self._state in ("preparing", "printing", "paused"):
                raise DriverError("Printer is busy")
            time.sleep(1)  # pretend upload
            self._file = req.remote_name
            self._fail = "fail" in req.remote_name.lower()
            self._state = "preparing"
            self._started = time.monotonic()

    def pause(self) -> None:
        with self._lock:
            if self._state == "printing":
                self._state, self._paused_at = "paused", time.monotonic()

    def resume(self) -> None:
        with self._lock:
            if self._state == "paused":
                self._started += time.monotonic() - self._paused_at
                self._state = "printing"

    def cancel(self) -> None:
        with self._lock:
            if self._state in ("preparing", "printing", "paused"):
                self._state, self._file = "idle", ""

    def snapshot(self) -> bytes | None:
        from PIL import Image, ImageDraw

        s = self.status()
        im = Image.new("RGB", (640, 360), (28, 30, 34))
        d = ImageDraw.Draw(im)
        # Bed, and a part that grows with progress.
        d.polygon([(120, 300), (520, 300), (470, 230), (170, 230)], fill=(60, 64, 70))
        h = int(120 * s.progress / 100)
        if h:
            d.rectangle([280, 270 - h, 360, 270], fill=(230, 120, 40))
        d.rectangle([300, 40, 340, 70 + (120 - h)], fill=(90, 94, 100))  # toolhead
        d.text((16, 14), f"{self.config.name}  {s.state}  {s.progress:.0f}%", fill=(240, 240, 240))
        d.text((16, 332), time.strftime("%H:%M:%S"), fill=(160, 160, 160))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=80)
        return buf.getvalue()
