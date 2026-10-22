"""Common interface every printer driver implements.

Drivers are used from the print manager's threads. Each one keeps its own connection and
must be safe to call from more than one thread.
"""

from dataclasses import asdict, dataclass, field
from pathlib import Path
from time import time

# offline | idle | preparing | printing | paused | finished | failed
STATES = ("offline", "idle", "preparing", "printing", "paused", "finished", "failed")


@dataclass
class Temp:
    temp: float | None = None
    target: float | None = None


@dataclass
class AmsSlot:
    unit: int
    slot: int
    type: str = ""
    color: str = ""  # #RRGGBB
    remaining: int | None = None  # percent, when the printer reports it


@dataclass
class Status:
    state: str = "offline"
    progress: float = 0  # 0-100
    layer: int | None = None
    total_layers: int | None = None
    remaining_s: int | None = None
    file: str = ""
    nozzle: Temp = field(default_factory=Temp)
    bed: Temp = field(default_factory=Temp)
    ams: list[AmsSlot] = field(default_factory=list)
    message: str = ""  # printer error or offline reason
    updated_at: float = field(default_factory=time)

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass
class MachineConfig:
    id: int
    name: str
    kind: str
    host: str
    serial: str
    secret: str


@dataclass
class PrintRequest:
    path: Path  # local file to send
    remote_name: str  # name to store it under on the printer
    plate: int = 1
    # Bambu only: AMS tray index per filament in the sliced file, -1 for the external spool.
    ams_mapping: list[int] = field(default_factory=list)
    options: dict = field(default_factory=dict)


class DriverError(Exception):
    """Something the user should see, such as a refused connection or a busy printer."""


class Driver:
    kind = ""
    label = ""
    # Formats from formats.print_format that this printer can print.
    formats: set[str] = set()
    has_camera = False
    # Connection fields shown in printer setup: (key, label, is_secret).
    fields: list[tuple[str, str, bool]] = [("host", "Address", False)]

    def __init__(self, config: MachineConfig):
        self.config = config

    def start(self) -> None:
        """Open long-lived connections. Called once from the manager thread."""

    def stop(self) -> None:
        """Close connections. The driver is discarded afterwards."""

    def status(self) -> Status:
        raise NotImplementedError

    def send(self, req: PrintRequest) -> None:
        """Upload the file and start printing it. Blocks until the printer has accepted the job."""
        raise NotImplementedError

    def pause(self) -> None:
        raise NotImplementedError

    def resume(self) -> None:
        raise NotImplementedError

    def cancel(self) -> None:
        raise NotImplementedError

    def snapshot(self) -> bytes | None:
        """One JPEG frame from the printer camera, or None when there is no camera."""
        return None
