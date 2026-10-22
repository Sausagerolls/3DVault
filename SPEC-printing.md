# 3DVault — Printing specification

Send models from 3DVault straight to a printer, slicing on the server when needed, then follow the print live from the phone. Agreed with the owner on 2026-10-22. Extends [SPEC.md](SPEC.md).

## Decisions

| Topic | Decision |
|---|---|
| Printers | Bambu Lab (LAN mode), Klipper (Moonraker), Prusa (PrusaLink), OctoPrint |
| Route | Everything goes through the 3DVault server. Clients never talk to printers. |
| Files | Pre-sliced files are sent as-is. STL/3MF/OBJ/STEP are sliced on the server. |
| Slicer | OrcaSlicer CLI, bundled in the main image (build arg `WITH_SLICER=false` leaves it out). |
| Profiles | Orca's bundled vendor profiles plus profiles imported from the desktop slicer. |
| Control | Live status, pause / resume / cancel, camera, push notifications and Live Activities. |
| Filament | Filament profile per print, plus AMS / AMS lite slot mapping for multicolour. |
| Who can print | Every signed-in user. Printer setup is admin only. |
| Platforms | iOS first, with web and Mac using the same server API. Printer setup lives in web Settings. |
| Print flow | Always open the full print sheet. |
| Preview | Summary (time, grams, cost, plate image) plus a layer-by-layer toolpath preview. |
| History | Every job is logged against the model and sets the user's print status to Printed or Failed. |
| Discovery | Bambu SSDP and mDNS scan, with manual IP fallback. The main container moves to host networking. |
| Sliced output | Saved to the model as a file named after printer and profile, for reprinting. |
| Busy printer | Jobs queue per printer. The next job starts only after someone taps "Bed cleared". |
| Notifications | APNs push and Live Activities. The APNs key lives on the server only, never in the repo. |
| Testing | Simulated printers for every protocol, then real-hardware checks on a Bambu A1 mini. |
| App Review | The demo server gets a simulated "Demo A1 mini" that accepts jobs and fakes progress and camera. |

## Bambu notes
- The printer must be in **LAN Only mode with Developer Mode on**. Bambu cloud and Bambu Handy stop working with the printer while that is on.
- Connection: MQTT over TLS on port 8883 (user `bblp`, password = LAN access code), file upload over implicit FTPS on port 990, both identified by the printer's serial number.
- A1 / A1 mini / P1 cameras are a TLS JPEG stream on port 6000. X1 / H2 use RTSPS on 322.
- Prints are sent as `.gcode.3mf` with the plate number and the AMS mapping in the `project_file` command.

## Server

### Data
- `Machine` (table `machines`): a connected printer with `kind` (bambu / moonraker / prusalink / octoprint / simulated), `host`, `serial`, `secret` (access code or API key, encrypted at rest with a key in `/data/secret.key`), an optional link to a `Printer` bed-size profile, `enabled` and `needs_clear`. `Printer` stays as the bed-size profile used by the fits filter. Orca printer profile is added in phase 3.
- `SlicerProfile`: kind (printer / process / filament), name, source (vendor / imported), Orca JSON, owner.
- `PrintJob` (table `print_jobs`): model, source file, printer, user, plate, options JSON (including the AMS mapping), state (queued / slicing / sliced / uploading / printing / paused / finished / failed / cancelled), progress, layer, times, error, created/started/finished.
- `PushDevice`: user, APNs token, Live Activity push tokens per job.

### Services
- **Printer drivers**, one per kind, behind a common interface: `connect`, `status()`, `upload(file)`, `start(file, options)`, `pause`, `resume`, `cancel`, `camera_frame()`, `ams()`. One long-lived connection per Bambu printer (MQTT pushes state).
- **Slicer**: runs `orca-slicer --slice` in the worker with the chosen printer, process and filament profiles plus per-print overrides. It returns the `.gcode.3mf` and parses time, grams and plate images from it. Only one slice runs at a time, at low CPU priority.
- **Monitor**: tracks printer state, advances the queue, records job results, sets print status, and sends APNs pushes and Live Activity updates.
- **Discovery**: listens for SSDP on UDP 2021 (Bambu) and browses mDNS for `_moonraker`, `_octoprint` and `_prusalink`.

### API (sketch)
- `GET /machine-kinds`; `GET/POST/PATCH/DELETE /machines` (writes are admin only); `POST /machines/{id}/pause|resume|cancel|bed-cleared`; `GET /machines/{id}/camera` (JPEG snapshot). Later: `POST /machines/discover`, `/camera/stream` (MJPEG).
- `GET/POST /slicer/profiles`, `POST /slicer/profiles/import` (Orca / Bambu Studio / PrusaSlicer bundles).
- `GET /files/{id}/print-info` (format, plates, compatible printers); `POST /jobs` queues a pre-sliced file; `GET /jobs?machine_id=&model_id=&active=`; `POST /jobs/{id}/cancel`.
- Phase 3: `POST /print/slice` → summary and preview; `GET /jobs/{id}/preview` (layer toolpaths, compact binary).
- `POST /push/devices`, `POST /push/activities`.
- Server-sent events at `/events` for live status in web and Mac.

## iOS app
- Model page: a **Print** button opens the print sheet.
  - Choose the printer, plate (multi-plate 3MF), and printer / process / filament profiles.
  - Override layer height, supports, infill, walls, brim and scale.
  - Map the AMS: each model colour to a printer slot, with colours read live from the printer.
  - Tap Slice to see the summary and layer preview, then Send (or Queue when the printer is busy).
- New **Printers** tab:
  - Status, progress, temperatures and the camera for each printer.
  - Pause, resume and cancel.
  - The queue, with "Bed cleared".
- Live Activity on the Lock Screen and Dynamic Island while a print runs. Pushes when a print finishes or fails.
- New capabilities: Push Notifications, Live Activities (`NSSupportsLiveActivities`), and a widget extension for the activity.

## Web and Mac
- Web Settings: add and discover printers, import profiles, see printer status, and use the Print dialog on the model page.
- Mac: Print button and printer status, using the same API as iOS.

## Phases
1. **Server foundation** (done 2026-10-22): printer model, driver interface, simulated printer, job queue, send pre-sliced files, status API, and the iOS print sheet for pre-sliced files plus the Printers tab.
2. **Bambu LAN driver**: MQTT, FTPS, AMS read and mapping, camera. Tested against a protocol simulator, then the A1 mini.
3. **Server slicing**: Orca CLI in the image, vendor and imported profiles, per-print overrides, summary and layer preview, saving the sliced file to the model.
4. **Push**: APNs, Live Activities and the widget extension.
5. **Moonraker, PrusaLink and OctoPrint drivers**.
6. **Web and Mac clients**, plus the demo server mock printer and review notes, then release.

## Release
The owner chose to replace the 1.0.1 submission in App Review with the printing build. The submission is only pulled once that build is finished and tested, so 1.0.1 keeps its place in the queue until then.
