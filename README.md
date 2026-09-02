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
Local credential reset is fail-closed: a durable marker in a dedicated
`UserDefaults` suite is written before Keychain mutation, tokens and the primary
session marker are removed and read back for verification, and the marker is
cleared only after all three values are absent. While a reset is pending the
app exposes no credentials and cannot restore a session, including after a
process restart; the retained installation `device_id` is outside this reset.

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

The main tab bar contains **Nearby** and **Profile**. **Nearby** keeps profiles
in discovery order instead of re-sorting rows whenever RSSI changes; coarse
distance labels are recalculated every 10 seconds. **Met**, **Saved**, and
**Blocked** are separate push destinations in Profile. A resolved encounter
starts a one-minute heartbeat buffer that is refreshed by every BLE signal and
persisted at bounded intervals.
After a full minute without a signal, the last real signal is published to
**Met** and removed from the pending buffer. If iOS terminates the app before
that timeout can run, the persisted buffer is published on the next launch
before scanning restarts. Met snapshots remain local for up to 24 hours, and a
later nearby discovery does not remove the existing history entry. New Met
profiles remain marked until their rows become visible. The application icon
badge combines the current Nearby count with only the unviewed Met count.

Saving a profile stores its public snapshot only on the current device. Saved
profiles never become an API collection and do not synchronize between devices.
They remain until the user removes them or clears the local account through
sign-out or account deletion. Profile settings also expose optional quick chat,
quick clear, and quick block actions that skip their usual confirmation step.

Both Core Bluetooth background modes and state restoration remain enabled while
scanning is on. Background identity connections are left pending for iOS to
complete instead of being cancelled by the foreground timeout. Restored pending
connections are reattached before scanning resumes, and failed background GATT
reads receive a bounded retry because iOS coalesces duplicate scan events while
both apps are suspended. After reading a peer identity, the discovering phone
writes its own identity back through a dedicated GATT characteristic, so one
asymmetric system discovery records the encounter on both phones. The raw UUID
and timestamp are persisted before profile lookup, preventing a short background
network window or process termination from losing an already detected encounter.
An explicit scan disable or account stop closes the discovery callback gate,
cancels pending identity recovery, and removes unresolved identities; callbacks
already queued by Core Bluetooth carry the old scan epoch and cannot repopulate
Nearby or Met even if scanning is re-enabled before their main-thread delivery.
Epoch transitions are synchronous on Core Bluetooth's own serial queue. GATT,
service-publication, and advertising requests retain their originating epoch;
a connection from the next account is deferred until the previous peripheral
operation reaches a terminal callback.
An abrupt process termination does not run that explicit cleanup, so persisted
pending identities remain available to the documented launch recovery path.
Core Bluetooth still provides no prompt-discovery guarantee when both iPhones
are already backgrounded with their screens off; the bilateral exchange begins
only after iOS delivers at least one discovery event.

The in-app information screen links directly to the current Terms of Service
and Privacy Policy.

## Reports and blocking

The nearby-profile sheet uses native menus, confirmation dialogs, and alerts.
Users submit one universal profile report and may add a short optional comment.
The API captures the target BIO together with the name, username, and photo
context. Reports are submitted through the authenticated API with a client
request UUID so a token refresh or retry does not create duplicate pending
reports.

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
| Peer identity write characteristic | `A6B50004-8A5D-4F7A-9E4C-123456789004` |
| Peer write encoding | 16 UUID bytes followed by one signed RSSI byte |
| Characteristic access | Identity values readable; peer exchange writable |

The advertisement contains only the fixed service UUID, so the user identity
cannot be truncated by the local-name payload limit. A scanner reads the compact
characteristic once, writes its identity and observed RSSI back when the peer
supports the optional exchange characteristic, caches the peripheral-to-identity
mapping, and periodically revalidates it. The text characteristic and optional
write negotiation keep staged upgrades compatible with older app versions.
Nearby profile lookup uses the authenticated
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
instead of producing one notification per profile. People already visible when
the app enters the background establish the notification baseline and do not
trigger another alert; only people detected after that transition contribute to
the batch. A quiet period starts a new encounter. A profile contributes only
after authenticated resolution succeeds, and cached blocks continue to suppress
notifications while the API is temporarily unavailable.

## Local storage

- Keychain: access token, refresh token, the primary-session marker, and
  installation `device_id`. Credential deletion is guarded by the separate
  durable reset marker described above.
- `UserDefaults`: public `telescan_id`, profile metadata, registration state,
  discovery state, BLE restoration identity, and the current account's cached
  blocked-profile UUIDs. It also stores device-local saved public profile
  snapshots, resolved encounter-profile snapshots, and at most 500 unresolved
  BLE identities with their last-seen timestamps. Encounter entries older than
  24 hours are removed. Neither Saved nor Met is uploaded.
- App storage and caches: selected/cached profile images and HTTP responses.

The encounter history can be cleared from **Met**. Met and Saved are also
cleared from persistence and in-memory singleton state on sign-out or account
deletion, preventing one account from inheriting another account's local
profiles in the same process. The clear link code and Telegram ID are not
persisted by the current app.

## Verification

Unit tests cover BLE manager state and identity encoding, resolved-only nearby
profiles, disappearance cancellation, automatic link-code success/error UI
state, offline-safe session validation, stable installation identity, token
refresh and retry, single-flight concurrent refresh, stable discovery ordering,
10-second distance refresh, application badge aggregation, fail-closed
Keychain deletion faults and restart behavior, queued callbacks across explicit
BLE stop/reset/re-enable epochs, local-state reset, and 24-hour encounter-history persistence,
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
