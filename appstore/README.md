# Releasing to the App Store

The iOS app (iPhone and iPad) and the Mac app are one App Store record with universal purchase, so both use the bundle ID `com.3dvault.mac`:

| Platform | Bundle ID | Extras |
| --- | --- | --- |
| iOS | `com.3dvault.mac` | Share extension `com.3dvault.mac.share`, App Group `group.com.3dvault.shared` |
| Mac | `com.3dvault.mac` | App Sandbox |

The store text, keywords and App Review notes are in [metadata.md](metadata.md). The privacy policy is [PRIVACY.md](../PRIVACY.md).

## Already done in the project

- Signing: automatic, team `J4UJD4Z33J`, for both apps.
- Versions: `MARKETING_VERSION` in each `project.yml` is the store version. `scripts/release.sh` sets the build number to a UTC timestamp.
- Mac App Sandbox, with network client, user-selected files and security-scoped bookmarks. The Inbox folder is chosen in Settings, because a sandboxed app cannot watch `~/3DVault/Inbox` on its own.
- Privacy manifests (`PrivacyInfo.xcprivacy`) in the iOS app, the Share extension and the Mac app. They declare no tracking, no collected data, and the required reasons for UserDefaults and file timestamps.
- `ITSAppUsesNonExemptEncryption = NO`. The apps only use the system's HTTPS. This skips the export-compliance question on every upload.
- App icons: iOS 1024 px, and the full Mac set.

## One-time setup in App Store Connect

1. Sign in at https://appstoreconnect.apple.com. Accept any pending agreements under Business.
2. Create one app under Apps > + > New App with both iOS and macOS ticked and bundle ID `com.3dvault.mac`.
   If the bundle ID is not in the list, build once with `scripts/release.sh` (it registers IDs automatically) or add it at https://developer.apple.com/account/resources/identifiers.
3. Under App Privacy, answer "No, we do not collect data from this app".
4. Fill in the listing from [metadata.md](metadata.md).

## Demo server for App Review

App Review must be able to sign in, so it needs a 3DVault server reachable from the internet with a demo account and a few models. Without one the app is rejected under guideline 2.1.

The demo server is https://demo3dvault.giantmushroom.studio. It is the `3DVault-Demo` container on the Unraid server (port 8001), published through a Cloudflare tunnel. Its data is separate from the real library. Put the address and the demo account in the App Review notes and the "Sign-in required" fields. The account details are kept out of this public repository.

To rebuild its sample library:

1. Generate the models: `server/.venv/bin/python appstore/demo/generate_models.py /tmp/demo-models`. This writes 12 procedurally generated models. They are original, so there are no licensing questions.
2. Copy the model folders into the demo's inbox (`/mnt/user/appdata/3dvault-demo/inbox`). They import once an admin account exists.
3. File them into categories with tags and notes: `docker exec -i 3DVault-Demo python - < appstore/demo/curate.py`.

## Each release

1. Bump `MARKETING_VERSION` in `ios/project.yml` and `mac/project.yml`.
2. Archive and upload:

   ```sh
   scripts/release.sh ios --upload
   scripts/release.sh mac --upload
   ```

   Without `--upload`, the script exports `dist/ios/3DVault.ipa` and `dist/mac/3DVault.pkg` instead. You can upload these with Apple's Transporter app. Uploading needs your Apple ID signed in under Xcode > Settings > Accounts, or an App Store Connect API key in `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER`.
3. In App Store Connect, wait for the build to finish processing. Optionally test it in TestFlight first.
4. Attach the build to the version and submit it for review.

## Screenshots

App Store Connect needs at least one screenshot per device family:

- **iPhone 6.9"** (1320 × 2868) and **iPad 13"** (2064 × 2752). Run this against a server with good-looking models:

  ```sh
  VAULT_TEST_SERVER=http://<server>:8000 VAULT_TEST_USER=<user> VAULT_TEST_PASSWORD=<password> \
    VAULT_TEST_MODEL=<model id> scripts/screenshots.sh
  ```

  It saves library and model screens, light and dark, to `dist/screenshots`.
- **Mac** (2880 × 1800, 2560 × 1600, 1440 × 900 or 1280 × 800). Size the window, press ⌘⇧4, then Space, and click the window. Crop or pad the image to one of those sizes.

## Things to know

- **Sandbox move on the Mac.** The sandboxed Mac app keeps its settings, caches and offline models in `~/Library/Containers/com.3dvault.mac`. Existing installs sign in once more, choose the Inbox folder again, and re-pin offline models.
- **Plain HTTP.** Both apps allow plain-HTTP connections (`NSAllowsArbitraryLoads`), because home servers rarely have certificates. The review notes explain this. If App Review objects, the fallback is `NSAllowsLocalNetworking`. That fallback covers IP addresses and `.local` names, but not other plain-HTTP hostnames.
