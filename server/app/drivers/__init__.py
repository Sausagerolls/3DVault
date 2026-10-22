"""Printer drivers by kind."""

from .base import Driver, DriverError, MachineConfig, PrintRequest, Status
from .simulated import SimulatedDriver

DRIVERS: dict[str, type[Driver]] = {d.kind: d for d in (SimulatedDriver,)}

__all__ = ["DRIVERS", "Driver", "DriverError", "MachineConfig", "PrintRequest", "Status"]
