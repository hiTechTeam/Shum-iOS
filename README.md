# Shum iOS

English · [Русский](README.ru.md)

Shum for iPhone. Meet people nearby over Bluetooth and stay connected through independent Nostr relays. No phone number required.

## Features

- Text messages over Bluetooth without internet, or through internet relays.
- End-to-end encryption and encrypted history on the device.
- Profile and conversation backups.
- App passcode, biometric unlock and privacy in the app switcher.
- Pixel avatars generated locally from a seed.
- Self-contained QR cards that can be added while the owner is offline.

Saving a contact and accepting a chat invitation are separate actions. Messages travel through Bluetooth or independent relays. A developer-operated server sends push notifications without receiving message text.

The app implements the current v1 draft. Multi-device sync and migration to the shared Rust core are planned.

## Project

Open `ShumiOS.xcodeproj` in Xcode. Dependencies and upstream revisions are recorded in the repository. Third-party code retains its original licenses.

[Protocol](https://github.com/hiTechTeam/Shum-Protocol) · [Rust core](https://github.com/hiTechTeam/Shum-Core) · [CLI](https://github.com/hiTechTeam/Shum-CLI) · [Upstream sources](Upstreams/README.md)

## Support and policies

[Issues](https://github.com/hiTechTeam/Shum-iOS/issues) · [Privacy](PRIVACY.md) · [Terms](TERMS.md)

## License

[MIT](LICENSE.md), © 2021–2026 Ruslan Chukavin. [Third-party licenses](Upstreams/README.md), including the [Bluetooth Unlicense](BLUETOOTH-LICENSE), remain applicable.
