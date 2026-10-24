import BitFoundation
import Foundation
import ShumCore
import Testing
@preconcurrency @testable import Shum

/// The profile on Shum-Core's session: a new profile opens with its signed
/// card, changes go through Shum-Core and stay in the database, and backups
/// come in the format every Shum client restores.
@Suite("Shum-Core session on the iPhone", .serialized)
@MainActor
struct ShumCoreSessionTests {
    @MainActor
    struct Person {
        let identity: ShumIdentityService
        let card: ShumContactCard
        let database: URL

        init(_ name: String) throws {
            let keychain = MockKeychain()
            identity = try ShumIdentityService(keychain: keychain, bridge: NostrIdentityBridge(keychain: keychain))
            card = try identity.card(name: name, bio: "")
            database = FileManager.default.temporaryDirectory
                .appendingPathComponent("shum-core-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("state.enc")
        }

        /// Opens the profile on Shum-Core with relays nobody answers.
        func open() throws -> ShumMessageStore {
            try ShumRuntime.coreStore(identity: identity, card: card, name: card.name,
                                      database: database, relays: ["ws://127.0.0.1:9"], push: nil)
        }
    }

    private func settle() async {
        // Requests to Shum-Core run in tasks on the main actor.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func aNewProfileOpensWithItsSignedCard() async throws {
        let anya = try Person("Аня")
        do {
            let store = try anya.open()
            #expect(store.ownCard.id == anya.card.id)
            #expect(store.ownCard.name == "Аня")
            #expect(store.state.contacts.isEmpty)
            store.retire()
        }
        await settle()
        let reopened = try anya.open()
        #expect(reopened.ownCard.id == anya.card.id, "the database keeps the profile")
        reopened.retire()
    }

    @Test func contactsPinsAndTheAddressBookGoThroughShumCore() async throws {
        let anya = try Person("Аня"), boris = try Person("Борис")
        do {
            let store = try anya.open()
            try store.add(boris.card, source: "test")
            await settle()
            #expect(store.isAddressBookContact(boris.card))
            #expect(try store.togglePinned(boris.card, in: "contacts"))
            await settle()
            #expect(store.isPinned(boris.card, in: "contacts"))
            try store.removeFromContacts(boris.card)
            await settle()
            #expect(!store.isAddressBookContact(boris.card))
            store.retire()
        }
        await settle()
        let reopened = try anya.open()
        #expect(reopened.state.pinnedDirectoryEntries?["contacts"] == [boris.card.id])
        #expect(reopened.state.contacts.first { $0.id == boris.card.id }?.isAddressBookEntry == false)
        reopened.retire()
    }

    @Test func backupsComeFromShumCoreInTheFormatEveryClientReads() async throws {
        let anya = try Person("Аня")
        let store = try anya.open()
        let backups = ShumBackupService()
        backups.core = store.core
        let file = try await backups.create(password: "длинный пароль 1")
        #expect(file.starts(with: Data("SHUM-BACKUP-2\n".utf8)))
        #expect(try backups.metadata(for: file).profileName == anya.card.name)
        let opened = try openBackup(file: file, password: "длинный пароль 1")
        #expect(opened.ownerId == anya.card.id)
        store.retire()
    }
}
