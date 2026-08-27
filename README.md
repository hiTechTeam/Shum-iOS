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

Create local build settings from the tracked templates before the first build:

```sh
cp TelescaniOS/Configuration/Configs/Debug.example.xcconfig \
  TelescaniOS/Configuration/Configs/Debug.xcconfig
cp TelescaniOS/Configuration/Configs/Release.example.xcconfig \
  TelescaniOS/Configuration/Configs/Release.xcconfig
```

Local `Debug.xcconfig` and `Release.xcconfig` files are ignored by Git and
excluded from the application bundle. Keep only non-secret templates in source
control. The tracked Release template points to `https://api.tgtelescan.ru`,
whose production traffic enters through the Netherlands EU relay and continues
to Moscow over WireGuard.

## Authentication and account lifecycle

Debug builds use a temporary Telegram-code sign-in so the app can run on a
physical iPhone signed by a free Personal Team. The Debug target intentionally
has no Sign in with Apple entitlement. Release builds retain the entitlement
and mandatory Apple-first flow. Remove `TELESCAN_PERSONAL_TEAM` and disable the
server compatibility flag after paid-team signing is available.

Use the shared `Telescan` scheme for Personal Team development. Use
`Telescan Release` to run the Apple-first build in a simulator now or on a
physical device after the paid Apple Developer team is available. Archive and
Profile actions always use Release.

1. The welcome screen opens a separate identity-verification step. Its system
   Sign in with Apple control creates or resumes the primary Telescan account
   through `POST /api/v1/auth/apple`. The request includes an Apple identity
   token, a cryptographic nonce, and a random installation `device_id`. Debug
   shows a matching non-Apple placeholder that continues to the temporary
   Telegram-code development flow without requiring the Apple entitlement.
2. Access and refresh tokens are stored in the iOS Keychain before Telegram is
   requested. Until Telegram is linked, relaunching returns to the mandatory
   linking screen rather than asking for Apple authentication again. A versioned
   Keychain marker distinguishes this primary Apple session from tokens issued
   by the legacy Telegram-only flow; legacy tokens return to Apple sign-in.
3. The user creates a public Telegram username and requests a short-lived,
   one-time code from the bot. The app submits it with the Apple-authenticated
   session to `POST /api/v1/users/me/telegram/link`.
4. The clear code is cleared from memory after the attempt and is never stored
   locally or logged.
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
The profile screen shows a BIO field. Tapping it opens a native resizable
editor where the optional 36-character BIO can be applied or cleared without
requesting another Telegram code. Bluetooth scanning is controlled from a
settings sheet opened through the profile's More menu. Nearby profile sheets
show a non-empty BIO in up to three lines above a primary action that opens the
linked Telegram profile; BIO text is rendered as plain text and never as an
active link.

The main tab bar contains **People** and **Profile**. **People** keeps
profiles in discovery order instead of re-sorting rows whenever RSSI changes;
coarse distance labels are recalculated every 10 seconds. The toolbar opens the
full-height **Met** history. After a resolved profile remains absent for five
minutes, its last-seen snapshot is kept locally for up to 24 hours. A later
nearby discovery does not remove the existing history entry.

The in-app information screen links directly to the current Terms of Service
and Privacy Policy.

## Reports and blocking

The nearby-profile sheet uses native menus, confirmation dialogs, and alerts.
Users can report a profile for spam, harassment, inappropriate content,
impersonation, or another reason and may add a short optional comment. The API
captures the target BIO together with the name, username, and photo context. Reports
are submitted through the authenticated API with a client request UUID so a
token refresh or retry does not create duplicate pending reports.

Blocking succeeds on the API before the profile is removed locally. A block is
enforced in both profile-lookup directions, immediately removes the person from
the nearby list, encounter history, and open sheet, and excludes the UUID from
numeric background notifications. The last successful blocked-ID list is
cached locally so an offline launch does not reintroduce blocked profiles.
Users can review and unblock profiles from **Blocked** in the profile More menu.

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
or unavailable profiles never create `Unknown` rows. Devices expire after 60
seconds without a sighting in either foreground or background operation. RSSI
is processed locally into a coarse distance hint and is never uploaded.
When signal silence starts the grace period, the nearby list displays a compact
`N s` countdown and the expanded profile displays `Disappears in N seconds`;
either label clears immediately when a fresh signal arrives.

Requested scan and advertising state is kept separately from CoreBluetooth
manager readiness. Scan, connection, service, and advertising commands are
issued only after the corresponding manager reaches `.poweredOn`; state delegate
callbacks resume deferred work. This avoids API-misuse warnings during launch,
Bluetooth power transitions, and state restoration.

When the app is backgrounded, nearby notifications contain aggregate numeric
counts rather than profile names. Discoveries are coalesced into numeric batches
instead of producing one notification per profile, and a quiet period starts a
new encounter. A profile contributes only after authenticated resolution
succeeds, and cached blocks continue to suppress notifications while the API is
temporarily unavailable.

## Local storage

- Keychain: access token, refresh token, and installation `device_id`.
- `UserDefaults`: public `telescan_id`, profile metadata, registration state,
  discovery state, BLE restoration identity, and the current account's cached
  blocked-profile UUIDs. It also stores at most 500 resolved encounter-profile
  snapshots with their last-seen timestamps; entries older than 24 hours are
  removed and the history is never uploaded.
- App storage and caches: selected/cached profile images and HTTP responses.

The encounter history can be cleared from **Met** and is also cleared on sign
out or account deletion. The clear link code and Telegram ID are not persisted
by the current app.

## Verification

Unit tests cover BLE manager state and identity encoding, resolved-only nearby
profiles, disappearance cancellation, automatic link-code success/error UI
state, offline-safe session validation, stable installation identity, token
refresh and retry, single-flight concurrent refresh, stable discovery ordering,
10-second distance refresh, and 24-hour encounter-history persistence,
deduplication, filtering, and cleanup. Example commands:

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

GitHub Actions runs the test suite and an unsigned Release simulator build for
every pull request and push to `main`. CI also verifies the production API
origin, Bluetooth background modes, privacy manifest, permission-text
localizations, and rejects forbidden local configuration files in the generated
app.

The `.app` bundle must not contain `.gitignore`, `.swiftlint.yml`,
`project.yml`, or local `.xcconfig` files. Xcode `xcuserdata` is ignored and is
not part of the repository. The app-owned `PrivacyInfo.xcprivacy` declares
`UserDefaults` access under Apple's `CA92.1` required reason; dependency privacy
manifests remain bundled separately with their frameworks.

Public product, privacy, terms, and security-contact information live in
[`Telescan-info`](https://github.com/hiTechTeam/Telescan-info). Cross-service
architecture and engineering risks live in the private
[`Telescan-internal-docs`](https://github.com/hiTechTeam/Telescan-internal-docs)
repository.

## License

Proprietary and confidential. See [LICENSE.md](LICENSE.md).
