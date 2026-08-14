import Foundation

struct DeviceIdentity {
    private let store: SecureStoring
    private let key: String

    init(
        store: SecureStoring = KeychainStore.shared,
        key: String = "telescan.installation.device-id"
    ) {
        self.store = store
        self.key = key
    }

    func value() throws -> UUID {
        if let data = try store.data(for: key),
           let string = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: string) {
            return id
        }
        let id = UUID()
        try store.set(Data(id.uuidString.utf8), for: key)
        return id
    }
}
