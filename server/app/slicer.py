"""Server-side slicing with the OrcaSlicer command line.

Orca's system profiles inherit from each other ("Bambu PLA Basic @BBL A1M" inherits
"Bambu PLA Basic @base", and so on), but the command line only reads the keys in the files
it is given. So every profile is flattened along its inherits chain before slicing.
Imported profiles from a desktop slicer live in <data>/slicer/profiles and may inherit
from system profiles the same way.
"""

import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
import zipfile
from pathlib import Path

from .config import settings

log = logging.getLogger("vault.slicer")

ORCA_BIN = os.environ.get("VAULT_ORCA_BIN", "/opt/orca/AppRun")
SYSTEM_DIR = Path(os.environ.get("VAULT_ORCA_PROFILES", "/opt/orca/resources/profiles"))
SLICE_TIMEOUT = int(os.environ.get("VAULT_SLICE_TIMEOUT", "1800"))
TYPES = ("machine", "process", "filament")

# Settings the print sheet can change, with how to write them into the process profile.
OVERRIDES = {
    "layer_height": lambda v: str(float(v)),
    "sparse_infill_density": lambda v: f"{int(v)}%",
    "wall_loops": lambda v: str(int(v)),
    "enable_support": lambda v: "1" if v else "0",
    "support_type": lambda v: str(v),  # normal(auto) | tree(auto) | normal(manual) | tree(manual)
    "brim_type": lambda v: str(v),  # auto_brim | outer_only | no_brim | ...
    "sparse_infill_pattern": lambda v: str(v),
}


def available() -> bool:
    return Path(ORCA_BIN).exists() and SYSTEM_DIR.is_dir()


def user_dir() -> Path:
    d = settings.data_dir / "slicer" / "profiles"
    for t in TYPES:
        (d / t).mkdir(parents=True, exist_ok=True)
    return d


class ProfileIndex:
    """Every system and imported profile by type and name. Built once, rebuilt after imports."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: dict[tuple[str, str], list[dict]] | None = None

    def invalidate(self) -> None:
        with self._lock:
            self._entries = None
            self.__dict__.pop("_types", None)

    def entries(self) -> dict[tuple[str, str], list[dict]]:
        with self._lock:
            if self._entries is None:
                self._entries = self._build()
            return self._entries

    def _build(self) -> dict[tuple[str, str], list[dict]]:
        out: dict[tuple[str, str], list[dict]] = {}
        roots = []
        if SYSTEM_DIR.is_dir():
            roots += [(v.name, v, False) for v in sorted(SYSTEM_DIR.iterdir()) if v.is_dir()]
        roots.append(("User", user_dir(), True))
        for vendor, root, user in roots:
            for t in TYPES:
                for path in (root / t).rglob("*.json"):
                    try:
                        data = json.loads(path.read_text(encoding="utf-8"))
                    except (OSError, ValueError):
                        continue
                    name = data.get("name") or path.stem
                    out.setdefault((t, name), []).append({
                        "path": path, "vendor": vendor, "user": user, "name": name,
                        "inherits": data.get("inherits", ""),
                        "instantiation": str(data.get("instantiation", "true" if user else "false")).lower() == "true",
                        "compatible_printers": data.get("compatible_printers") or [],
                        "printer_model": data.get("printer_model", ""),
                        "filament_type": (data.get("filament_type") or [""])[0] if isinstance(data.get("filament_type"), list) else data.get("filament_type", ""),
                    })
        return out

    def find(self, t: str, name: str, vendor: str | None = None) -> dict | None:
        cands = self.entries().get((t, name)) or []
        if not cands:
            return None
        # User profiles win, then the same vendor as the child, then Orca's shared filament library.
        for pick in (
            lambda e: e["user"],
            lambda e: vendor and e["vendor"] == vendor,
            lambda e: e["vendor"] == "OrcaFilamentLibrary",
        ):
            for e in cands:
                if pick(e):
                    return e
        return cands[0]

    def flatten(self, t: str, name: str, vendor: str | None = None, _depth: int = 0) -> dict:
        e = self.find(t, name, vendor)
        if e is None:
            raise ValueError(f"Unknown {t} profile: {name}")
        if _depth > 20:
            raise ValueError(f"Profile inheritance loop at {name}")
        data = json.loads(e["path"].read_text(encoding="utf-8"))
        parent = data.get("inherits")
        merged = self.flatten(t, parent, e["vendor"] if not e["user"] else vendor, _depth + 1) if parent else {}
        merged.update(data)
        merged.pop("inherits", None)
        return merged

    def machine_model(self, printer: str) -> dict:
        """The printer model file a printer preset belongs to ("Bambu Lab A1 mini"). It holds
        settings such as the default plate type that presets don't carry."""
        e = self.find("machine", printer)
        if e is None:
            return {}
        flat = self.flatten("machine", printer)
        model = self.find("machine", flat.get("printer_model", ""), e["vendor"])
        if model is None:
            return {}
        try:
            data = json.loads(model["path"].read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if data.get("type") == "machine_model" else {}

    def filament_type(self, name: str) -> str:
        """Material of a filament profile, which usually comes from a parent profile."""
        cache = self.__dict__.setdefault("_types", {})
        if name not in cache:
            try:
                v = self.flatten("filament", name).get("filament_type") or [""]
                cache[name] = v[0] if isinstance(v, list) else str(v)
            except ValueError:
                cache[name] = ""
        return cache[name]

    def printers(self) -> list[dict]:
        return sorted(
            ({"name": e["name"], "vendor": e["vendor"], "model": e["printer_model"], "user": e["user"]}
             for (t, _), es in self.entries().items() if t == "machine" for e in es if e["instantiation"]),
            key=lambda p: (p["vendor"] != "User", p["vendor"], p["name"]),
        )

    def for_printer(self, t: str, printer: str) -> list[dict]:
        """Process or filament profiles that list `printer` as compatible."""
        base_names = {printer}
        e = self.find("machine", printer)
        if e and e["user"] and e["inherits"]:
            base_names.add(e["inherits"])  # a user printer is compatible with its system parent's profiles
        out = []
        for (tt, _), es in self.entries().items():
            if tt != t:
                continue
            for p in es:
                if not p["instantiation"]:
                    continue
                compat = set(p["compatible_printers"])
                if p["user"] and not compat and p["inherits"]:
                    parent = self.find(t, p["inherits"])
                    compat = set(parent["compatible_printers"]) if parent else set()
                if compat & base_names:
                    out.append({"name": p["name"], "vendor": p["vendor"], "user": p["user"],
                                "type": self.filament_type(p["name"]) if t == "filament" else ""})
        return sorted(out, key=lambda p: (not p["user"], p["name"]))


profiles = ProfileIndex()


# ---------------------------------------------------------------- import


def import_profiles(filename: str, data: bytes) -> list[str]:
    """Store profiles exported from Orca, Bambu Studio or PrusaSlicer-style JSON.

    Accepts a single .json preset, or a zip / .orca_printer / .orca_filament / .bbscfg bundle
    of them. Returns the names imported.
    """
    names = []
    if filename.lower().endswith(".json"):
        names.append(_store(json.loads(data)))
    else:
        import io

        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for n in z.namelist():
                if n.lower().endswith(".json") and not n.startswith("__MACOSX"):
                    try:
                        names.append(_store(json.loads(z.read(n))))
                    except (ValueError, KeyError):
                        continue
    profiles.invalidate()
    return [n for n in names if n]


def _store(data: dict) -> str:
    t = data.get("type")
    name = data.get("name")
    if t not in TYPES or not name:
        return ""
    safe = re.sub(r"[^\w .@()+-]", "_", name)[:120]
    (user_dir() / t / f"{safe}.json").write_text(json.dumps(data, indent=1), encoding="utf-8")
    return name


# ---------------------------------------------------------------- slicing


def slice_files(inputs: list[Path], printer: str, process: str, filaments: list[str], overrides: dict, out_path: Path) -> str:
    """Slice `inputs` into a .gcode.3mf at out_path. Returns the tail of Orca's log for errors."""
    if not available():
        raise RuntimeError("OrcaSlicer isn't installed in this server image")
    with tempfile.TemporaryDirectory(dir=settings.cache_dir) as tmp:
        d = Path(tmp)
        machine = profiles.flatten("machine", printer)
        machine["name"] = printer
        proc = profiles.flatten("process", process)
        for k, v in (overrides or {}).items():
            if k in OVERRIDES and v is not None:
                proc[k] = OVERRIDES[k](v)
        fil = [profiles.flatten("filament", f) for f in (filaments or [])] or []
        files = {"machine.json": machine, "process.json": proc}
        for i, f in enumerate(fil):
            files[f"filament{i}.json"] = f
        for fname, data in files.items():
            # The files are now complete. Orca's command line treats a "system" printer's own name
            # as its identity and only accepts a process whose compatible_printers lists it.
            # Compatibility was already checked when the profiles were offered.
            data["from"] = "system"
            data.pop("inherits", None)
            if fname != "machine.json":
                data["compatible_printers"] = [machine["name"]]
                data["compatible_printers_condition"] = ""
            (d / fname).write_text(json.dumps(data), encoding="utf-8")
        out_dir = d / "out"
        out_dir.mkdir()
        base = [ORCA_BIN, "--datadir", str(d / "orca-data")]
        env = {**os.environ, "HOME": str(d)}

        # Pass 1: arrange the models with our profiles into an unsliced project.
        cmd = [
            *base, "--arrange", "1", "--orient", "1", "--ensure-on-bed",
            "--load-settings", f"{d / 'machine.json'};{d / 'process.json'}",
            "--outputdir", str(d), "--export-3mf", "project.3mf",
        ]
        if fil:
            cmd += ["--load-filaments", ";".join(str(d / f"filament{i}.json") for i in range(len(fil)))]
        scale = (overrides or {}).get("scale")
        if scale and float(scale) != 1:
            cmd += ["--scale", str(float(scale))]
        if any(p.suffix.lower() == ".3mf" for p in inputs):
            # Projects saved by a newer Bambu Studio or Orca still slice fine in practice.
            cmd += ["--allow-newer-file"]
        cmd += [str(_sliceable(p, d, [machine, proc, *fil])) for p in inputs]
        log_tail = _run(cmd, d, env, d / "project.3mf")

        # Orca only reads the plate type and filament colours from a project, not from profile
        # files or the command line, so set them in the project before slicing it. The plate
        # defaults to the printer's own (Textured PEI on an A1 mini).
        bed = (overrides or {}).get("bed_type") or profiles.machine_model(printer).get("default_bed_type")
        colours = (overrides or {}).get("filament_colours") or []
        _patch_project(d / "project.3mf", d / "ready.3mf", bed, colours)

        # Pass 2: slice every plate.
        log_tail = _run([*base, "--slice", "0", "--outputdir", str(out_dir), "--export-3mf", "result.gcode.3mf",
                         str(d / "ready.3mf")], d, env, out_dir / "result.gcode.3mf")
        result = out_dir / "result.gcode.3mf"
        shutil.move(result, out_path)
        return log_tail


def _sliceable(path: Path, tmp: Path, profile_values: list[dict]) -> Path:
    """Orca's command line reads STL, OBJ, AMF and 3MF. Convert STEP to a fine STL first.

    A 3MF project carries its own slicer settings, and Bambu Studio projects can hold values
    Orca refuses (such as -1 for raft_first_layer_expansion). Overwrite them with the chosen
    profiles, which the slice uses anyway, and drop any old G-code.
    """
    ext = path.suffix.lower()
    if ext == ".3mf":
        out = tmp / f"input-{path.name}"
        with zipfile.ZipFile(path) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                name = item.filename
                if name.startswith("Metadata/plate_") and name.endswith((".gcode", ".gcode.md5")):
                    continue
                data = zin.read(name)
                if name == "Metadata/project_settings.config":
                    data = json.dumps(_merge_settings(json.loads(data), profile_values), indent=1).encode()
                zout.writestr(item, data)
        return out
    if ext in (".step", ".stp"):
        from .mesh import load_mesh

        out = tmp / f"{path.stem}.stl"
        load_mesh(path).export(out)
        return out
    return path


# Project-level settings that belong to the 3MF itself rather than to a profile.
PROJECT_KEYS = {
    "version", "curr_bed_type", "filament_colour", "filament_settings_id", "print_settings_id",
    "printer_settings_id", "flush_volumes_matrix", "flush_volumes_vector", "flush_multiplier",
    "filament_map", "filament_map_mode", "first_layer_print_sequence", "other_layers_print_sequence",
    "other_layers_print_sequence_nums", "different_settings_to_system", "nozzle_volume_type",
}


def _merge_settings(project: dict, profile_values: list[dict]) -> dict:
    skip = {"name", "from", "inherits", "type", "instantiation", "compatible_printers",
            "compatible_printers_condition", "compatible_prints", "compatible_prints_condition", "setting_id"}
    n = len(project.get("filament_colour") or [1])
    known = set().union(*(v.keys() for v in profile_values))
    for k in list(project):
        # Settings no profile defines fall back to Orca's defaults instead of the project's value.
        if k not in known and k not in PROJECT_KEYS:
            del project[k]
    for values in profile_values:
        is_filament = values.get("type") == "filament"
        for k, v in values.items():
            if k in skip or k not in project:
                continue
            if is_filament and isinstance(v, list) and len(v) == 1:
                v = v * n  # one filament profile used for every filament slot in the project
            project[k] = v
    return project


def _run(cmd: list[str], cwd: Path, env: dict, expect: Path) -> str:
    try:
        r = subprocess.run(["nice", "-n", "10", *cmd], capture_output=True, timeout=SLICE_TIMEOUT, cwd=cwd, env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Slicing took longer than {SLICE_TIMEOUT // 60} minutes")
    log_tail = (r.stdout + r.stderr).decode(errors="replace")[-4000:]
    if r.returncode != 0 or not expect.exists():
        log.warning("orca failed (%s): %s", r.returncode, log_tail[-1500:])
        raise RuntimeError(_slice_error(log_tail, r.returncode))
    return log_tail


def _patch_project(src: Path, dst: Path, bed: str | None, colours: list[str]) -> None:
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == "Metadata/project_settings.config":
                cfg = json.loads(data)
                if bed:
                    cfg["curr_bed_type"] = bed
                if colours:
                    n = len(cfg.get("filament_colour") or colours)
                    cfg["filament_colour"] = [colours[i] if i < len(colours) else colours[-1] for i in range(n)]
                data = json.dumps(cfg, indent=1).encode()
            zout.writestr(item, data)


# Orca's command-line exit codes (src/libslic3r/Utils.hpp), seen by the shell as 256 + code.
CLI_ERRORS = {
    -3: "A model file couldn't be read.",
    -4: "A 3MF project can't be sliced together with other files. Slice it on its own.",
    -5: "One of the slicer profiles is invalid.",
    -14: "The server ran out of memory while slicing.",
    -17: "The process profile doesn't suit this printer.",
    -21: "The models don't fit on the plate together. Try fewer parts or a smaller scale.",
    -50: "There was nothing on the plate to slice.",
    -51: "The slicer rejected these settings.",
    -52: "Part of the model is outside the printable area. Try a smaller scale.",
    -61: "This filament can't be used on the chosen build plate.",
    -62: "These filaments need temperatures too far apart to print together.",
    -65: "Spiral vase mode needs one part with one wall and no infill.",
    -100: "The slicer hit an error. The model may need repairing.",
    -101: "Toolpaths collide with each other.",
    -102: "Toolpaths reach outside the printable area. Try a smaller scale.",
}


def _slice_error(log_tail: str, code: int) -> str:
    signed = code - 256 if code > 127 else code
    if signed in CLI_ERRORS:
        return CLI_ERRORS[signed]
    last = [l for l in log_tail.strip().splitlines() if l.strip()][-1:]
    return f"Slicing failed ({signed}): {last[0][:300] if last else 'no output'}"
