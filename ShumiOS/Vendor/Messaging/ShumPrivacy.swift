import Foundation

/// A durable marker keeps a failed/interrupted deletion from reopening radios
/// or silently creating replacement keys on the next launch.
@MainActor
final class ShumDeletionService {
    private let marker: URL
    private let directories: [URL]
    private let deleteKeys: () -> Bool
    private let clearPreferences: () -> Void
    init(marker: URL, directories: [URL], deleteKeys: @escaping () -> Bool, clearPreferences: @escaping () -> Void) {
        self.marker = marker; self.directories = directories
        self.deleteKeys = deleteKeys; self.clearPreferences = clearPreferences
    }
    var hasDeletion: Bool { FileManager.default.fileExists(atPath: marker.path) }
    var completed: Bool { (try? String(contentsOf: marker, encoding: .utf8)) == "deleted" }
    func begin() throws { try writeMarker("pending") }
    func finish() throws {
        guard hasDeletion else { throw ShumFailure.storage }
        // Remove files before committing success. A partial failure leaves the
        // marker and the app closed; Retry is safe even after key deletion.
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if entry.standardizedFileURL == marker.deletingLastPathComponent().standardizedFileURL { continue }
                try FileManager.default.removeItem(at: entry)
            }
        }
        guard deleteKeys() else { throw ShumFailure.unavailableIdentity }
        clearPreferences()
        try writeMarker("deleted")
    }
    func allowNewProfile() throws {
        guard completed else { throw ShumFailure.storage }
        try FileManager.default.removeItem(at: marker)
    }
    private func writeMarker(_ value: String) throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: marker, options: .atomic)
        var folder = marker.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
    static func live() -> ShumDeletionService {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ShumDeletionService(marker: support.appendingPathComponent("ShumPrivacy/deletion.state"),
            directories: [support, files.urls(for: .cachesDirectory, in: .userDomainMask)[0], files.urls(for: .documentDirectory, in: .userDomainMask)[0], files.temporaryDirectory],
            deleteKeys: { KeychainManager.makeDefault().deleteAllKeychainData() },
            clearPreferences: { if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) } })
    }
}

#if os(iOS)
import SwiftUI

#endif
