# Upstream Sources

English · [Русский](README.ru.md)

Revisions are pinned in [versions.json](versions.json). Updates are reviewed before they reach the app.

## Sources

- [Bitchat](https://github.com/permissionlesstech/bitchat), Unlicense: Bluetooth mesh, Noise, courier delivery and protocol utilities. Reviewable code is materialized in `.upstreams/bitchat`.
- [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS), GPL-2.0-or-later: interaction and component reference only. Telegram source is not copied or compiled into Shum; interactions are implemented independently.

Shum's Bluetooth integration sits behind `Transport` in [Transport.swift](../ShumiOS/Vendor/Bluetooth/Services/Transport.swift). `BitchatTransportFactory` creates the production BLE engine. Upstream files never overwrite the working transport automatically.

## Update workflow

1. Run `Scripts/upstreams/status.sh` to compare pinned revisions with upstream heads.
2. Run `Scripts/upstreams/fetch.sh all` to fetch pinned commits.
3. Run `Scripts/upstreams/materialize-bitchat.sh` for review.
4. Move reviewed changes across the Transport boundary.
5. Verify build, messaging, discovery, courier delivery and migration before updating versions.json.

Run scripts from the repository root.
