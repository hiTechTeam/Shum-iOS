import Foundation
import Security

protocol SecureStoring: AnyObject {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

enum SecureStoreError: Error {
    case unhandledStatus(OSStatus)
    case invalidData
    case resetIncomplete
}
