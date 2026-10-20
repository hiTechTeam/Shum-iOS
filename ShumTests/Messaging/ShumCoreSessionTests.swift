import BitFoundation
import CryptoKit
import Foundation
import ShumCore
import Testing
@preconcurrency @testable import Shum

/// The switch to Shum-Core's session: a profile written by this app's own
/// session opens in Shum-Core unchanged, and talks to a phone that still runs
/// the old session over Bluetooth.
@Suite("Shum-Core session on the iPhone", .serialized)
@MainActor
struct ShumCoreSessionTests {
    typealias Node = ShumPermanentTests.Node

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shum-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Opens `node`'s database in Shum-Core's session instead of the app's.
    private func switchToCore(_ node: Node, url: URL) throws -> ShumMessageStore {
        let session = try ShumCoreSession(
            profile: MobileProfile(
                database: url.path,
                id: node.card.id,
                name: node.card.name,
                relays: ["ws://127.0.0.1:9"],
                push: false,
                client: "{}",
                encounterRetentionHours: 0
            ),
            keys: node.identity.coreKeys,
            push: nil
        )
        return try ShumMessageStore(core: session, identity: node.identity, transport: node.wire, wire: node.wire)
    }

    /// Delivers Bluetooth packets between the old-session phone and the
    /// Shum-Core phone until both are quiet.
    private func drain(old: Node, core: Node, coreStore: ShumMessageStore) {
        for _ in 0..<50 {
            var work = false
            for (to, data) in old.wire.shumPackets where to == core.wire.myPeerID {
                work = true
                coreStore.receiveBytes(data, from: old.wire.myPeerID)
            }
            old.wire.shumPackets.removeAll()
            for (to, data) in core.wire.shumPackets where to == old.wire.myPeerID {
                work = true
                old.service.receiveBytes(data, from: core.wire.myPeerID)
            }
            core.wire.shumPackets.removeAll()
            if !work { return }
        }
    }

    private func settle() async {
        // Requests to Shum-Core run in tasks on the main actor.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func aProfileFromTheOldSessionOpensInShumCoreAndKeepsTalking() async throws {
        let clock = ShumPermanentTests.Clock()
        let dir = try folder()
        let anyaURL = dir.appendingPathComponent("anya.sqlite")
        let anya = try Node("Аня", clock: clock, url: anyaURL)
        let boris = try Node("Борис", clock: clock)
        let suite = ShumPermanentTests()
        try suite.allowBoth(anya, boris, clock: clock)
        suite.connect(anya, boris, clock: clock)
        #expect(anya.service.send("Привет из старой сессии", to: boris.card))
        suite.drain([anya, boris])
        #expect(boris.service.state.messages.contains { _ in true })

        // Anya's phone switches to Shum-Core on the same database.
        let history = anya.service.state.messages.count
        let core = try switchToCore(anya, url: anyaURL)
        #expect(core.state.messages.count == history, "history opens unchanged")
        #expect(core.state.contacts.contains { $0.id == boris.card.id })
        #expect(core.invitationPhase(for: boris.card) == .accepted)
        #expect(core.ownCard.id == anya.card.id)

        // Bluetooth still links the phones; Shum-Core learns Boris is nearby.
        core.tick(connected: [boris.wire.myPeerID], active: true)
        boris.service.tick(connected: [anya.wire.myPeerID], active: true)
        drain(old: boris, core: anya, coreStore: core)
        await settle()
        #expect(core.nearby[boris.wire.myPeerID]?.id == boris.card.id)

        // Anya writes through Shum-Core; the old session receives it.
        #expect(core.send("Привет из ядра", to: boris.card))
        await settle()
        let sent = anya.wire.shumPackets.count
        let outgoing = (core.core?.snapshot()["messages"] as? [[String: Any]] ?? []).filter { $0["outgoing"] as? Bool == true }
        #expect(sent > 0, "Shum-Core sent over Bluetooth; outgoing: \(outgoing)")
        drain(old: boris, core: anya, coreStore: core)
        await settle()
        drain(old: boris, core: anya, coreStore: core)
        #expect(boris.service.state.messages.count >= 2, "message from Shum-Core arrived")

        // Every change is Shum-Core's: the app's own storage refuses writes.
        #expect(throws: (any Error).self) { try core.store.transaction { _ in } }
        core.retire()
    }

    @Test func pinsAndTheAddressBookGoThroughShumCore() async throws {
        let clock = ShumPermanentTests.Clock()
        let dir = try folder()
        let url = dir.appendingPathComponent("anya.sqlite")
        let anya = try Node("Аня", clock: clock, url: url)
        let boris = try Node("Борис", clock: clock)
        try ShumPermanentTests().allow(anya, to: boris, clock: clock)
        let core = try switchToCore(anya, url: url)
        #expect(try core.togglePinned(boris.card, in: "contacts"))
        await settle()
        #expect(core.isPinned(boris.card, in: "contacts"))
        try core.removeFromContacts(boris.card)
        await settle()
        #expect(!core.isAddressBookContact(boris.card))
        core.retire()

        // The same database opens in the app's own session with the changes.
        let reopened = try ShumConversationStore(ownerID: anya.card.id, key: anya.identity.storageKey, url: url)
        #expect(reopened.state.pinnedDirectoryEntries?["contacts"] == [boris.card.id])
        #expect(reopened.state.contacts.first { $0.id == boris.card.id }?.isAddressBookEntry == false)
    }

    @Test func backupsComeFromShumCoreInTheFormatEveryClientReads() async throws {
        let clock = ShumPermanentTests.Clock()
        let url = try folder().appendingPathComponent("anya.sqlite")
        let anya = try Node("Аня", clock: clock, url: url)
        let core = try switchToCore(anya, url: url)
        let backups = ShumBackupService()
        backups.core = core.core
        let file = try await backups.create(password: "длинный пароль 1")
        #expect(file.starts(with: Data("SHUM-BACKUP-2\n".utf8)))
        #expect(try backups.metadata(for: file).profileName == anya.card.name)
        let opened = try openBackup(file: file, password: "длинный пароль 1")
        #expect(opened.ownerId == anya.card.id)
        core.retire()
    }
}
