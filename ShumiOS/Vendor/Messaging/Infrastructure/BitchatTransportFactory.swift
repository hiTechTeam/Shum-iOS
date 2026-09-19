import Foundation
import BitFoundation

/// The single composition point between Shum and the vendored Bitchat transport.
/// Upstream transport updates stay behind `Transport`; product services do not
/// construct or configure Bitchat dependencies independently.
enum BitchatTransportFactory {
    static func make(
        keychain: KeychainManagerProtocol,
        deferBluetoothStartup: Bool = false
    ) -> BLEService {
        BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            identityManager: SecureIdentityStateManager(keychain),
            deferBluetoothStartup: deferBluetoothStartup
        )
    }
}
