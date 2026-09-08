# Telescan for iOS

SwiftUI app that discovers nearby Telescan users over Bluetooth Low Energy and
opens the public Telegram profiles they choose to share.

## Setup

Requires iOS 17.6+, Xcode and a physical iPhone for BLE testing.

```sh
./ci_scripts/ci_post_clone.sh
open TelescaniOS.xcodeproj
```

Use the `Telescan` scheme for Personal Team development. Debug temporarily
supports Telegram-code authentication because free signing cannot use Sign in
with Apple. `Telescan Release` keeps the production Apple-first flow.
Release signing uses FrameLabs LLC; Personal Team Debug is unchanged.

## Product behavior

- Telegram is linked with a short-lived one-time bot code.
- Access and refresh tokens are stored in Keychain and cleared on sign-out.
- BLE advertises only a random Telescan ID, never Telegram credentials.
- Profiles appear only after authenticated API resolution.
- RSSI and distance stay on device and are approximate.
- **Met** keeps local encounters for 24 hours; **Saved** is also device-only.
- Reports and bidirectional blocks are enforced by the API.
- Account deletion removes server data and clears account-scoped local state.

Background BLE delivery is controlled by iOS and is not guaranteed when both
devices remain suspended. Telescan must not be used for navigation, safety or
proof of physical presence.

## Verification

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

GitHub Actions runs tests and validates an unsigned production archive on every
pull request and push to `main`.
Xcode Cloud and GitHub Actions create missing local configs from public templates
with `ci_scripts/ci_post_clone.sh`; existing configs are preserved. App Store
uploads also require access to cloud-managed distribution certificates.

## License

Proprietary and confidential. See [LICENSE.md](LICENSE.md).
