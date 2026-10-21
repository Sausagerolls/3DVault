# 3DVault for iPhone and iPad

SwiftUI app for iOS/iPadOS 26 and later, plus a Share extension. It talks to the same server as the web and Mac apps.

## Build

```sh
brew install xcodegen
cd ios && xcodegen generate && open 3DVault-iOS.xcodeproj
```

To run on a device:
1. Set your team in `project.yml` (`DEVELOPMENT_TEAM`) or under Signing & Capabilities for **both** targets (3DVault and 3DVaultShare).
2. Change the bundle IDs (`com.3dvault.mac`, `com.3dvault.mac.share`) and the App Group (`group.com.3dvault.shared`) to ones under your account if Xcode says they are taken. Keep the App Group and keychain group the same in both targets, or the Share extension can't see your sign-in.
3. Run. Sign in with the server address you use in the browser (over Tailscale, the NAS's tailnet name).

The Simulator runs without a team. For quick testing, a Debug build signs in by itself when launched with `VAULT_TEST_SERVER`, `VAULT_TEST_USER` and `VAULT_TEST_PASSWORD` in the environment, and `VAULT_TEST_MODEL=<id>` opens a model.

## Using it

- **Library:** the sidebar has your sections, pinned items, collections, categories and tags. Pull to refresh.
- **Touch and hold a model** for a spinning 3D preview plus actions (share, send to Mac, keep offline, favourite, status, category, collection, trash).
- **Select** (top right) to pick several models, then **Actions** for bulk changes.
- **Share / To Mac:** downloads the printable files (a slicer project if there is one, otherwise every mesh) and opens the share sheet. "To Mac" hides most other targets so AirDrop is easy to find.
- **Upload:** the **+** button picks files or folders from Files, iCloud Drive or an SMB share, then shows the same review step as the Mac. You can also use **Share → 3DVault** from Safari downloads, Files, Mail or Photos, or "Open in 3DVault".
- **Print photos:** on a model, add photos from your library or take one with the camera.
- **Offline:** "Keep Offline" saves a model's files on the device. When the server can't be reached, the app shows those models.

## Layout
- `App/`: the app.
- `Share/`: the Share extension.
- `../VaultKit/` and `../Shared/`: code shared with the Mac app.
