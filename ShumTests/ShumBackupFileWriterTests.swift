import Foundation
import Testing
@testable import Shum

struct ShumBackupFileWriterTests {
    @Test func savedExportStartsCompletionRegardlessOfCallbackOrder() {
        var delegateFirst = ShumBackupPickerCompletion()
        #expect(delegateFirst.didComplete(saved: true) == nil)
        #expect(delegateFirst.didDismiss() == true)
        #expect(delegateFirst.didDismiss() == nil)

        var dismissalFirst = ShumBackupPickerCompletion()
        #expect(dismissalFirst.didDismiss() == nil)
        #expect(dismissalFirst.didComplete(saved: true) == true)
        #expect(dismissalFirst.didComplete(saved: true) == nil)
    }

    @Test func cancelledExportNeverReportsSuccess() {
        var completion = ShumBackupPickerCompletion()
        #expect(completion.didDismiss() == nil)
        #expect(completion.didComplete(saved: false) == false)
    }

    @Test func repeatedBackupsPreserveEarlierFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstData = Data("first encrypted backup".utf8)
        let nextData = Data("next encrypted backup".utf8)
        let first = try ShumBackupFileWriter.save(firstData, in: folder, filename: "Shum.shumbackup")
        let second = try ShumBackupFileWriter.save(nextData, in: folder, filename: "Shum.shumbackup")

        #expect(first != second)
        #expect(try Data(contentsOf: first) == firstData)
        #expect(try Data(contentsOf: second) == nextData)
        #expect(second.pathExtension == "shumbackup")
    }

    @Test func unavailableDestinationReportsFailure() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: (any Error).self) {
            try ShumBackupFileWriter.save(Data([1, 2, 3]), in: file, filename: "Shum.shumbackup")
        }
        #expect(try Data(contentsOf: file) == Data("not a directory".utf8))
    }
}
