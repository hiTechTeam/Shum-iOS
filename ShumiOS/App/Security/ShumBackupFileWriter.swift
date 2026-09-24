import Foundation

enum ShumBackupFileWriter {
    /// Keep access and file-provider coordination alive until the write finishes.
    /// A repeated backup must never replace an earlier backup in the same folder.
    static func save(_ data: Data, in folder: URL, filename: String) throws -> URL {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        coordinator.coordinate(writingItemAt: folder, options: .forMerging, error: &coordinationError) { directory in
            result = Result {
                let original = directory.appendingPathComponent(filename)
                var destination = original
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = directory.appendingPathComponent(
                        "\(original.deletingPathExtension().lastPathComponent)-\(suffix)"
                    ).appendingPathExtension(original.pathExtension)
                    suffix += 1
                }
                try data.write(to: destination, options: .atomic)
                return destination
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
}
