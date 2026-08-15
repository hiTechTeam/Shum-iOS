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

The profile exposes one system account-actions alert with **Sign out on this
device**, **Delete account**, and **Cancel**. Sign-out and deletion each require
a separate destructive confirmation. Current-device sign-out revokes only its
session and clears local tokens and caches. Account deletion removes the server
account, photos, every device session, link codes, confirmation requests, and
local session and profile data. The installation `device_id` remains in
Keychain as an unlinked per-installation identifier for a later registration.

At launch and whenever the app returns to the foreground, it loads
`GET /api/v1/users/me`. A valid response refreshes the locally displayed
Telegram profile. A revoked or deleted account clears the local session and
returns to registration. Network errors, rate limits, and server failures during
profile validation or token refresh leave the session, tokens, cached profile,
and cached photo intact.
Starting a new link clears local image and URL caches before applying the fresh
Telegram profile returned by the API.

The in-app information screen links directly to the current Terms of Service
and Privacy Policy.

## BLE identity

The app advertises the user's random public `telescan_id`, never the Telegram
ID or an access token.

| Item | Value |
| --- | --- |
| Service UUID | `A6B50001-8A5D-4F7A-9E4C-123456789001` |
| Compact identity characteristic | `A6B50003-8A5D-4F7A-9E4C-123456789003` |
| Compact identity encoding | Full UUID as 16 lossless binary bytes |
| Compatibility characteristic | `A6B50002-8A5D-4F7A-9E4C-123456789002` |
| Compatibility encoding | Lowercase UUID text in UTF-8 |
| Characteristic access | Readable |

The advertisement contains only the fixed service UUID, so the user identity
cannot be truncated by the local-name payload limit. A scanner reads the compact
characteristic once, caches the peripheral-to-identity mapping, and periodically
revalidates it. The text characteristic keeps staged upgrades compatible with
older app versions. Nearby profile lookup uses the authenticated
`/api/v1/profiles/{telescan_id}` endpoint. A BLE candidate is not displayed until
the API returns a matching profile with a usable Telegram username; incomplete
or unavailable profiles never create `Unknown` rows. Devices expire after 10
seconds without a foreground sighting, with a 45-second background grace period.
RSSI is processed locally into a coarse distance hint and is never uploaded.

## Local storage

- Keychain: access token, refresh token, and installation `device_id`.
- `UserDefaults`: public `telescan_id`, profile metadata, registration state,
  discovery state, and the BLE restoration identity.
- App storage and caches: selected/cached profile images and HTTP responses.

The clear link code and Telegram ID are not persisted by the current app.

## Verification

Unit tests cover BLE manager state and identity encoding, resolved-only nearby
profiles, disappearance cancellation, automatic link-code success/error UI
state, offline-safe session validation, stable installation identity, token
refresh and retry, and single-flight concurrent refresh. Example commands:

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
not part of the repository. The app-owned `PrivacyInfo.xcprivacy` declares
`UserDefaults` access under Apple's `CA92.1` required reason; dependency privacy
manifests remain bundled separately with their frameworks.

Architecture, privacy, security, current limitations, and the roadmap live in
the [Telescan documentation](https://github.com/hiTechTeam/Telescan-info).

Licensed under the [MIT License](LICENSE.md).
