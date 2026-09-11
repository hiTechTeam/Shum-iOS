# Telescan for iOS — local Bluetooth version

Branch: `feature/local-bluetooth-profiles`. Local prototype, not deployed.

## Behavior

- Registration: choose/take a photo, then enter Telegram username and name.
- No Apple login, bot codes, API, server accounts or remote image loading.
- Phones exchange a signed local card and a small photo directly over BLE.
  The signature identifies the local card; it does **not** verify Telegram ownership.
- Existing nearby, approximate distance, 24-hour Met history, Saved and Telegram
  handoff remain. Blocking hides a card on this phone only; server reports are removed.
- Delete Card clears this phone’s data, not copies already received by others.
- Existing locally stored profile and saved contacts are preserved where available.

Both phones need this new version: it uses a different BLE service from the
previous server-backed release. iOS still controls background delivery; full
background discovery is not guaranteed.

## Build and test

Requires iOS 16.0+, Xcode and two physical iPhones for radio testing.
Run `./ci_scripts/ci_post_clone.sh`, open `TelescaniOS.xcodeproj`, select the
`Telescan` scheme and an authorized signing team (FrameLabs for the existing ID).
Debug and Release use the same offline behavior.

Tests cover packet fragmentation, two-way photo transfer, photo reuse,
signature/size validation, blocking, saved contacts and encounter history.

Before an App Store submission, update public privacy/review documentation for
this architecture and separately resolve moderation/review requirements.
No App Store approval is implied by this prototype.

## License

Proprietary and confidential. See [LICENSE.md](LICENSE.md).
