# 3DVault — Specification

Self-hosted library for 3D printing files. Docker server + web UI (phase 1), native macOS app (phase 2), iOS/iPadOS app (phase 3).

## Context
- Users: owner + family/friends, local accounts. Roles: **Admin** (users, settings) and **Member** (upload, tag, edit anything; delete own uploads only).
- Host: x86 NAS, Docker. Under 2k models. Remote access via Tailscale (no public exposure).
- Starting fresh — no legacy import.
- Slicers in use: Bambu Studio, OrcaSlicer, PrusaSlicer, Cura.

## Stack
- Backend: Python 3.12, FastAPI, SQLAlchemy, SQLite (FTS5 for search), Alembic migrations.
- Worker: background job queue in the same image (thumbnails, STEP conversion, metadata extraction, inbox watch, trash purge). Throttled for NAS CPUs.
- Frontend: React + TypeScript + Vite, three.js (react-three-fiber) viewer. Built into static files served by FastAPI.
- Single image, multi-stage build. `docker-compose.yml` provided.

## Docker volumes
| Mount | Purpose |
|---|---|
| `/library` | Human-readable model folders (source of truth for files) |
| `/data` | SQLite DB, thumbnails, converted previews, cache |
| `/inbox` | Watched drop folder (SMB share), auto-imported |

`PUID`/`PGID` env vars so files on the NAS are owned by the right user.

## Data model
- **Model** = a folder of files: meshes, images, docs, license, slicer projects.
- Disk layout: `/library/<model-slug>/` (flat, so category changes never move files). A `model.json` sidecar mirrors metadata so the library survives DB loss and can be re-indexed.
- Fields: name, description (markdown), category (one, hierarchical), tags (many, free), source URL, author, license, print notes (markdown), printer compatibility, cover image, created/updated, uploader.
- Files: type, size, SHA-256, bounding box (mm), triangle count, per-file thumbnail.
- Print photos: user-uploaded, can become cover.
- Per-user: favourite, star rating (1–5), print status (To print / Printed / Failed / Needs remix).
- Shared: problem flags (broken mesh, missing parts, bad scale, other + note).
- Collections: manual lists + saved smart filters.
- Trash: soft delete, restore in UI, auto-purge after 30 days.
- Dedupe: hash check on upload, warn with link to existing model. No version history.

## File formats
| Format | Preview |
|---|---|
| STL, OBJ, PLY | Direct in three.js; server thumbnail |
| 3MF (plain + Bambu/Orca/Prusa projects) | Mesh in three.js; extract embedded plate thumbnails |
| STEP/STP | Server converts to GLB via OpenCascade (OCP) once, cached in `/data` |
| G-code, .bgcode, UFP | Embedded thumbnail extraction; metadata (print time, filament) parsed where present |

Thumbnails rendered server-side, headless (CPU/OSMesa), queued and throttled.

## Web UI
- Dark-first theme, follows system light/dark.
- Printer presets for bed-fit filter: Bambu A1/P1/X1 (256×256×256), Bambu A1 mini (180×180×180), Prusa MK4/Core One (250×210×220), Prusa MINI (180×180×180). Custom printers definable in settings.
- Library grid: static thumbnails; hover shows a lightweight live 3D spin; click opens the detail page with the full viewer (orbit, wireframe, measure bbox, per-part toggle).
- Faceted sidebar: category tree, tags, print status, favourites, rating, problem flags, file type, uploader, date added, bed-fit (bbox ≤ X×Y×Z, printer presets), triangle count, part count.
- Full-text search over name, description, tags, filenames, author.
- Saved filters / smart collections.
- Multi-select in grid (shift/cmd-click) → bulk set category, add/remove tags, set flags/status, add to collection, delete.
- **Untriaged** queue: all new imports land here until categorised.
- Auto-tag rules: (filename/folder/source matches X) → add tags / set category.
- Download: single file, or whole model as zip.

## Upload / import
- Single file or multi-file drag-drop.
- Zip: auto-extract → one model; detect images, README, LICENSE.
- Many loose files: group by filename-prefix heuristic → review screen before commit.
- Folder tree drop: each subfolder → one model.
- Inbox watch on `/inbox`, same grouping rules.
- URL metadata import: Printables (public GraphQL), Thingiverse (API token in settings), MakerWorld (best effort; Cloudflare may block — fallback to manual).

## API
- REST, OpenAPI documented, versioned `/api/v1`. Web UI, Mac app and iOS app all use it.
- Auth: session cookie for web; per-device API tokens (revocable) for apps.

## macOS app (phase 2)
- SwiftUI, macOS 14+, signed + notarized DMG (developer account available).
- Connect to server URL + login → device token stored in Keychain.
- Browse/search/filter, detail with SceneKit/RealityKit 3D preview.
- Open in slicer (Bambu Studio, OrcaSlicer, PrusaSlicer, Cura) — download to cache and launch.
- Drag files out to Finder/slicer; drag-drop in (window + Dock icon) to upload.
- Pinned models cached offline.
- Watched local folder `~/3DVault/Inbox` → auto-upload.
- Shared Swift package for API client/models to reuse on iOS.

## iOS / iPadOS app (phase 3)
- SwiftUI, iOS 26+, universal (iPhone + iPad). Same features as the Mac app except launching slicers.
- Sidebar with library sections, pinned items, collections, categories, tags and trash; full-width grid; models open on top of the grid.
- Long-press a model for a spinning 3D preview and its actions; multi-select with a bulk actions sheet.
- Detail: 3D viewer (full screen, wireframe), status, rating, favourite, notes, tags, category, flags, files.
- Share and "Send to Mac" (share sheet narrowed towards AirDrop) instead of open-in-slicer.
- Uploads: Files picker (files and folders) with the same review step as the Mac; "Open in 3DVault"; print photos from Photos or the camera.
- Share extension: "Share → 3DVault" from Safari, Files, Mail or Photos uploads files as new models. Shares sign-in with the app through an App Group and a keychain access group.
- Offline: keep models on the device; shown when the server can't be reached.

## Out of scope (v1)
Printer integration (OctoPrint/Moonraker/Bambu), version history, SSO, public sharing links.
