"""Printer drivers by kind."""

from .base import Driver, DriverError, MachineConfig, PrintRequest, Status
from .bambu import BambuDriver
from .http import MoonrakerDriver, OctoPrintDriver, PrusaLinkDriver
from .simulated import SimulatedDriver

DRIVERS: dict[str, type[Driver]] = {d.kind: d for d in (BambuDriver, MoonrakerDriver, PrusaLinkDriver, OctoPrintDriver, SimulatedDriver)}

__all__ = ["DRIVERS", "Driver", "DriverError", "MachineConfig", "PrintRequest", "Status"]
