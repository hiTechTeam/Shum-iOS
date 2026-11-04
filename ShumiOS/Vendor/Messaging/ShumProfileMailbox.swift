import Foundation
import ShumCore

/// Only the open profile runs. When a push says something came for another
/// profile on this iPhone, this opens that profile on Shum-Core for a few
/// seconds, without Bluetooth or screens: the relays hand over what they keep
/// for it, its receipts go back so the sender sees the message delivered, and
/// its exact unread count goes to the list of profiles.
@MainActor
final class ShumProfileMailbox {
    static let shared = ShumProfileMailbox()

    private struct Run {
        let session: ShumCoreSession
        let task: Task<Bool, Never>
    }
    /// Fetches under way, by local profile ID.
    private var running: [String: Run] = [:]

    /// The longest wait for a relay to send what it stored, and how long
    /// receipts and their pushes then get to leave; a push grants about 30 s.
    private static let catchUpLimit: TimeInterval = 15
    private static let sendTime: UInt64 = 3_000_000_000

    /// Fetches the profile with this network ID if it is on this iPhone and
    /// not open. Returns whether its unread count changed.
    func fetch(identityID: String) async -> Bool {
        let profiles = ShumProfileList.shared
        guard let entry = profiles.entries.first(where: { $0.identityID == identityID }),
              entry.id != profiles.active else { return false }
        if let run = running[entry.id] { return await run.task.value }
        guard let session = Self.open(entry) else { return false }
        let id = entry.id
        let task = Task { @MainActor in await self.drain(session, profile: id) }
        running[id] = Run(session: session, task: task)
        let changed = await task.value
        if running[id]?.session === session { running[id] = nil }
        return changed
    }

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    /// Ends a fetch before its profile opens, so two sessions never share
    /// one database.
    func stop(profile id: String) async {
        guard let run = running.removeValue(forKey: id) else { return }
        run.task.cancel()
        await run.session.closeAndSettle()
    }

    private func drain(_ session: ShumCoreSession, profile id: String) async -> Bool {
        var caughtUp = false
        session.caughtUp = { caughtUp = true }
        session.wake()
        let start = Date()
        while !caughtUp, !Task.isCancelled, Date().timeIntervalSince(start) < Self.catchUpLimit {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !Task.isCancelled { try? await Task.sleep(nanoseconds: Self.sendTime) }
        let count = Task.isCancelled ? nil : await Self.unread(session)
        await session.closeAndSettle()
        let profiles = ShumProfileList.shared
        guard let count, profiles.active != id,
              let entry = profiles.entries.first(where: { $0.id == id }),
              entry.unread != count else { return false }
        profiles.setUnread(count, profile: id)
        return true
    }

    /// Registers every profile that is not open again, with a banner or
    /// quietly, after the owner changed that.
    func registerClosedProfiles() {
        let profiles = ShumProfileList.shared
        let quiet = !ShumPushService.inactiveProfilesNotify
        for entry in profiles.entries where entry.id != profiles.active {
            guard let (identity, card) = Self.identity(for: entry) else { continue }
            ShumPushService.shared.registerProfile(card: card, signer: { identity.sign($0) }, quiet: quiet)
        }
    }

    /// A listed profile's keys and signed card. Never creates either: a
    /// profile without its database, or whose keys no longer match it, is
    /// left alone.
    static func identity(for entry: ShumProfileList.Entry) -> (ShumIdentityService, ShumContactCard)? {
        let space = ShumProfileSpace(id: entry.id)
        guard FileManager.default.fileExists(atPath: ShumConversationStore.databaseURL(for: space).path) else { return nil }
        let keychain = KeychainManager.makeDefault()
        guard let identity = try? ShumIdentityService(keychain: keychain,
                                                      bridge: NostrIdentityBridge(keychain: keychain, space: space),
                                                      space: space),
              let card = try? identity.card(name: entry.name, bio: "", avatarSeed: entry.avatarSeed),
              card.id == entry.identityID else { return nil }
        return (identity, card)
    }

    /// Opens a listed profile's database with its keys.
    private static func open(_ entry: ShumProfileList.Entry) -> ShumCoreSession? {
        guard let (identity, card) = identity(for: entry) else { return nil }
        let database = ShumConversationStore.databaseURL(for: ShumProfileSpace(id: entry.id))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let push = ShumRuntime.pushURL
        return try? ShumCoreSession(
            profile: MobileProfile(
                database: database.path,
                id: card.id,
                name: entry.name,
                relays: ShumRuntime.sharedCoreRelays,
                push: push != nil,
                client: "{\"owner\":\"ios\",\"version\":\"\(version)\"}",
                encounterRetentionHours: UInt32(ShumMessageStore.encounterRetention / 3600)
            ),
            keys: identity.coreKeys,
            push: push
        )
    }

    private static func unread(_ session: ShumCoreSession) async -> Int? {
        await withCheckedContinuation { done in
            session.read(stored: true) { state, _ in
                done.resume(returning: (try? state?.get())?.awaitingCount)
            }
        }
    }
}
