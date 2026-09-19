# Upstream sources

Shum tracks two official repositories at explicit revisions. The revisions are
stored in `versions.json`, so an update is reproducible and does not silently
change application behavior.

## Bitchat

`upstream-bitchat` is the source for the Bluetooth mesh, Noise sessions,
courier delivery, packet models and protocol utilities. Its upstream license is
the Unlicense, so reviewed source changes can be imported into Shum.

The currently relevant upstream directories are:

- `bitchat/Identity`
- `bitchat/Models`
- `bitchat/Noise`
- `bitchat/Protocols`
- `bitchat/Services`
- `bitchat/Sync`
- `bitchat/Utils`

Shum keeps product behavior behind the `Transport` protocol in
`ShumiOS/Vendor/Bluetooth/Services/Transport.swift`. Upstream code is first
materialized into `.upstreams/bitchat` for review. It is never copied over the
working transport automatically because Shum has application-specific security,
storage and Nostr integration changes.

`BitchatTransportFactory` is the only production composition point that creates
the concrete BLE engine. The rest of Shum consumes the transport contract, so an
upstream update does not spread construction details through product code.

## Telegram-iOS

`upstream-telegram-ios` is a reference for interaction behavior and component
structure. Telegram-iOS is a Bazel application rather than an importable Swift
package, and its source is GPL-2.0-or-later. Shum therefore does not compile or
copy Telegram source. Equivalent interactions are implemented independently in
Shum behind small UI components.

This separation lets us follow Telegram changes without turning the whole Shum
application into a GPL-derived build.

## Workflow

1. Run `Scripts/upstreams/status.sh` to compare pinned revisions with current
   upstream heads.
2. Run `Scripts/upstreams/fetch.sh all` to fetch the pinned commits.
3. Run `Scripts/upstreams/materialize-bitchat.sh` to place the selected Bitchat
   source under `.upstreams/bitchat`.
4. Review the upstream diff and move only the intended transport changes across
   the `Transport` boundary.
5. Build Shum and verify messaging, discovery, courier delivery and migration
   before changing `versions.json`.
