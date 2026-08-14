# Telescan for iOS

SwiftUI social radar that discovers nearby Telescan users over Bluetooth Low
Energy and opens the public Telegram profiles they choose to share.

## Requirements and configuration

- Xcode with Swift 5 support;
- iOS 17.6 or newer;
- a physical iPhone for BLE discovery;
- an HTTPS Telescan API origin outside local development.

Open `TelescaniOS.xcodeproj` and use the `Telescan` scheme. The project reads
these build settings through `Configuration/Info.plist`:

| Setting | Purpose |
| --- | --- |
| `API_ORIGIN` | Base origin such as `https://api.tgtelescan.ru` |
| `TELESCAN_BOT` | Link to `https://t.me/tgtelescan_bot` |
| `LOCALHOST` | Optional Debug backend origin |

Local `Configuration/Configs/Debug.xcconfig` and `Release.xcconfig` files are
ignored by Git and excluded from the application bundle. Keep only non-secret
templates in source control.

## Authentication and account lifecycle

1. The user requests a short-lived, one-time link code from the Telegram bot.
2. The app submits the code and a random installation `device_id` directly to
   `POST /api/v1/auth/link`.
3. The clear code is cleared from memory after the attempt and is never stored
   locally or logged.
4. Access and rotating refresh tokens are stored in the iOS Keychain.
5. Protected requests automatically retry once after a coordinated token
   refresh; concurrent 401 responses share one refresh operation.

Signing out on the current device revokes only its session and clears local
tokens and caches. Signing out on every device requires confirmation through
the Telegram bot. While confirmation is pending, the app polls its status and
falls back to probing the authenticated session when connected to an older API
deployment without the status endpoint. Account deletion is a separate
authenticated operation that removes the server account, photos, sessions,
link codes, confirmation requests, and local session and profile data. The
installation `device_id` remains in Keychain as an unlinked per-installation
identifier for a later registration.

## BLE identity

The app advertises the user's random public `telescan_id`, never the Telegram
ID or an access token.

| Item | Value |
| --- | --- |
| Service UUID | `A6B50001-8A5D-4F7A-9E4C-123456789001` |
| Identity characteristic | `A6B50002-8A5D-4F7A-9E4C-123456789002` |
| Identity encoding | Lowercase UUID text in UTF-8 |
| Characteristic access | Readable |

The UUID is placed in the advertisement local name when iOS permits it;
otherwise a scanner connects and reads the characteristic. Nearby profile
lookup uses the authenticated `/api/v1/profiles/{telescan_id}` endpoint.
Devices disappear from the list after 20 seconds without a sighting. RSSI is
processed locally into a coarse distance hint and is never uploaded.

## Local storage

- Keychain: access token, refresh token, and installation `device_id`.
- `UserDefaults`: public `telescan_id`, profile metadata, registration state,
  discovery state, and the BLE restoration identity.
- App storage and caches: selected/cached profile images and HTTP responses.

The clear link code and Telegram ID are not persisted by the current app.

## Verification

Unit tests cover BLE manager state, automatic link-code success/error UI state,
logout-all confirmation monitoring, stable installation identity, token refresh
and retry, and single-flight concurrent refresh. Example commands:

```sh
xcodebuild test \
  -project TelescaniOS.xcodeproj \
  -scheme Telescan \
  -destination 'platform=iOS Simulator,name=iPhone 16'

xcodebuild build \
  -project TelescaniOS.xcodeproj \
  -scheme Telescan \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

The `.app` bundle must not contain `.gitignore`, `.swiftlint.yml`,
`project.yml`, or local `.xcconfig` files. Xcode `xcuserdata` is ignored and is
not part of the repository.

Architecture, privacy, security, current limitations, and the roadmap live in
the [Telescan documentation](https://github.com/hiTechTeam/Telescan-info).

Licensed under the [MIT License](LICENSE.md).
