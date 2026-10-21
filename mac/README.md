# 3DVault for Mac

Native SwiftUI client for the 3DVault server. Requires macOS 14 or later.

## Features
- Sign in once. The app stores a per-device token in the Keychain, and you can revoke it from the web UI under Settings → Account.
- Library grid with the same sections as the web: Untriaged, Favourites, Has problems, Collections, Categories and Trash. Search, filter by status, tags or fits-printer, and sort.
- Hover a card to spin the model in 3D. Selecting a model opens a full SceneKit viewer with wireframe mode.
- **Open in slicer:** double-click a model, or use the button or context menu. Supports Bambu Studio, OrcaSlicer, PrusaSlicer and UltiMaker Cura. Slicer projects open as they are; otherwise every mesh in the model opens together.
- **Drag out:** drag a model card or a file row to Finder, the Desktop or a slicer window. It downloads when you drop it.
- **Upload:** drop files or folders on the window or the Dock icon, use File → Upload Files… (⌘U), or right-click files in Finder and choose Open With → 3DVault. You review the grouping before anything is saved.
- **Inbox folder:** anything saved to `~/3DVault/Inbox` is uploaded automatically. Afterwards it moves to `Inbox/Imported/<date>`; nothing is deleted.
- **Keep on this Mac:** pin models for offline use. Pinned models stay viewable and openable in a slicer when the server is unreachable.
- **Edit:** name, category, tags, print status, rating, favourite, notes, problem flags, extra files and print photos. Bulk edit several models from the side panel or the context menu.

## Build
```sh
brew install xcodegen
cd mac && xcodegen generate && open 3DVault.xcodeproj
```
Set your team under Signing & Capabilities, then Run.

For a signed, notarised DMG to share with family: `TEAM_ID=XXXXXXXXXX scripts/release.sh`. The script lists its one-time setup at the top.

## Layout
- `App/`: the macOS app (SwiftUI).
- `../VaultKit/`: Swift package with the API client, models, Keychain, GLB mesh reader, 3D scene and upload helpers. Shared with the iOS app.
- `../Shared/`: app-level Swift shared with the iOS app (sidebar sections, pins, category/collection/tag actions).

## Tests
```sh
cd ../VaultKit && swift test                       # unit tests
VAULT_TEST_SERVER=http://localhost:8000 VAULT_TEST_USER=me VAULT_TEST_PASSWORD=… swift test   # plus live API tests
```
