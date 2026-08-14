# Telescan for iOS

SwiftUI social radar that discovers nearby Telescan users over Bluetooth Low Energy and opens the Telegram profiles they choose to share.

Open `TelescaniOS.xcodeproj` in Xcode and run the `Telescan` scheme on a device with iOS 17.6 or later. Bluetooth discovery requires a physical iPhone; set `API_ORIGIN` in the target's Debug and Release build settings or their `.xcconfig` files.

## Authentication and identity

The app links a device with a short-lived, one-time code obtained from the Telegram bot. The code is submitted directly to the API and is never persisted locally. Short-lived access tokens and rotating refresh tokens are stored in the iOS Keychain; protected API calls never use a Telegram identifier.

Each installation also has a random `device_id` in Keychain for session management. A user's public, random `telescan_id` is the only account identifier advertised over BLE and used for nearby-profile lookup. Logging out clears session tokens but keeps the installation `device_id`; deleting the account is a separate operation.

`API_ORIGIN` must be an HTTPS origin outside local development. The API is the sole owner of MongoDB and profile-photo storage; the iOS app communicates only with the public API.

Architecture, privacy, security, known issues, and the roadmap are kept in the [Telescan documentation](https://github.com/hiTechTeam/Telescan-info).

Licensed under the [MIT License](LICENSE.md).
