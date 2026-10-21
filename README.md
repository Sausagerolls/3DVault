# 3DVault

Self-hosted library for 3D printing files. It runs in one Docker container on a NAS, and you use it from the browser. There are native apps for Mac (`mac/`) and iPhone/iPad (`ios/`). The agreed design is in [SPEC.md](SPEC.md).

## Features (phase 1)

- Models are folders of files: STL, 3MF, OBJ, PLY, STEP/STP, G-code, .bgcode, UFP, images and docs.
- Thumbnails are rendered on the server (CPU only, no GPU needed). Hover a card for a live 3D spin, or open a model for the full orbit viewer.
- STEP files are converted with OpenCascade. Embedded thumbnails are pulled from Bambu, Orca, Prusa and Cura 3MF and G-code files, and print time and filament are parsed from G-code.
- Organise with a category tree, free tags, per-user favourites, ratings and print status (To print / Printed / Failed / Needs remix), and shared problem flags.
- Filter by search text, category, tags, status, rating, flags, file type, uploader, date added, fits-printer (with rotation), part count and triangle count. Save any filter as a smart collection, or build manual collections.
- Upload by dropping files, folders or zips anywhere in the app. Files are grouped automatically into models, and you review the grouping before saving. Duplicates are detected by hash.
- Inbox watch: files saved to the `inbox` share are imported automatically. Exact duplicates are moved to `inbox/_duplicates`.
- Bulk edit: select models with shift/cmd-click or Cmd+A, then set category, tags, status, favourite, flag, collection or trash for all of them at once.
- Untriaged queue and auto-tag rules.
- Import title, description, author, license, tags and images from a Printables, Thingiverse (needs a token) or MakerWorld (best effort) link.
- Trash with a 30-day purge. Download single files or a whole model as a zip.
- Local accounts with Admin and Member roles. Device tokens for the Mac app. REST API docs at `/api/docs`.

## Run on the NAS

```sh
docker compose up -d --build        # or load a prebuilt image, see below
```

Open `http://<nas>:8000` and create the admin account.

Edit `docker-compose.yml` first:

- `PUID` / `PGID`: the NAS user that should own the files. On Synology, run `id <user>` over SSH.
- Point the three volumes at real shares, for example `/volume1/3dvault/library`. Share `library` and `inbox` over SMB if you want to browse them in Finder.

### Build on a Mac for an x86 NAS

```sh
docker buildx build --platform linux/amd64 -t 3dvault:latest --load .
docker save 3dvault:latest | gzip > 3dvault.tar.gz
# copy to the NAS, then:  docker load < 3dvault.tar.gz
```

Build with `--build-arg WITH_STEP=false` to leave out STEP support. That saves about 300 MB.

### Remote access (Tailscale)

Install Tailscale on the NAS. The library is then at `http://<nas-tailnet-name>:8000` from anywhere on your tailnet. If you use `tailscale serve` for HTTPS, set `VAULT_COOKIE_SECURE=true`.

## Disk layout

```
library/<model-slug>/...files...      original files, readable without the app
library/<model-slug>/model.json       metadata sidecar (name, tags, category, notes…)
library/.trash/<model-slug>/          trashed models until purge
data/vault.db                         SQLite database
data/thumbs, data/previews            generated, safe to delete (use Rescan + reprocess)
inbox/                                auto-import drop folder
```

If the database is lost, **Settings → System → Rescan library folder** rebuilds models from the folders and `model.json` sidecars. Per-user status and ratings are not rebuilt. Files copied straight into a model folder over SMB are picked up by a rescan too.

## Backups

Back up `library/` and `data/vault.db` together. The NAS snapshot tools are fine for this. The thumbnails and previews can be regenerated.

## Development

```sh
cd server && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt cadquery-ocp
VAULT_LIBRARY=/tmp/v/library VAULT_DATA=/tmp/v/data VAULT_INBOX=/tmp/v/inbox .venv/bin/uvicorn app.main:app --port 8765 --reload
VAULT_LIBRARY=/tmp/v/library VAULT_DATA=/tmp/v/data VAULT_INBOX=/tmp/v/inbox .venv/bin/python -m app.worker
cd web && npm install && npm run dev    # http://localhost:5173, proxies /api to :8765
```

## Apps

- **Mac** (`mac/`, macOS 14+): browse, preview, open files in your slicer, keep models offline, drag-and-drop uploads, and a watched `~/3DVault/Inbox`. See [mac/README.md](mac/README.md).
- **iPhone and iPad** (`ios/`, iOS 26+): browse, 3D preview, organise, share or AirDrop files to your Mac, upload from Files or the Share sheet, add print photos, keep models offline. See [ios/README.md](ios/README.md).
- Both use the `VaultKit` Swift package for the API client and 3D previews.
