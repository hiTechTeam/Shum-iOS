import Foundation

/// A durable marker keeps a failed/interrupted deletion from reopening radios
/// or silently creating replacement keys on the next launch.
@MainActor
final class SpotchatDeletionService {
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
        guard hasDeletion else { throw SpotchatFailure.storage }
        // Remove files before committing success. A partial failure leaves the
        // marker and the app closed; Retry is safe even after key deletion.
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if entry.standardizedFileURL == marker.deletingLastPathComponent().standardizedFileURL { continue }
                try FileManager.default.removeItem(at: entry)
            }
        }
        guard deleteKeys() else { throw SpotchatFailure.unavailableIdentity }
        clearPreferences()
        try writeMarker("deleted")
    }
    func allowNewProfile() throws {
        guard completed else { throw SpotchatFailure.storage }
        try FileManager.default.removeItem(at: marker)
    }
    private func writeMarker(_ value: String) throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: marker, options: .atomic)
        var folder = marker.deletingLastPathComponent()
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
    static func live() -> SpotchatDeletionService {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SpotchatDeletionService(marker: support.appendingPathComponent("ShumPrivacy/deletion.state"),
            directories: [support, files.urls(for: .cachesDirectory, in: .userDomainMask)[0], files.urls(for: .documentDirectory, in: .userDomainMask)[0], files.temporaryDirectory],
            deleteKeys: { KeychainManager.makeDefault().deleteAllKeychainData() },
            clearPreferences: { if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) } })
    }
}

#if os(iOS)
import SwiftUI

struct SpotchatPrivacySettings: View {
    @ObservedObject var runtime: SpotchatRuntime
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    @State private var error: String?
    var body: some View {
        List {
            Section("Заблокированные") {
                let cards = (runtime.permanent?.state.blocked?.values.map { $0 } ?? []).sorted { $0.name < $1.name }
                if cards.isEmpty { Text("Нет заблокированных контактов").foregroundStyle(.secondary) }
                ForEach(cards) { card in
                    HStack {
                        Text(card.name); Spacer()
                        Button("Разблокировать") {
                            do { try runtime.permanent?.setBlocked(card, blocked: false) }
                            catch { self.error = error.localizedDescription }
                        }.font(.subheadline)
                    }
                }
            }
            Section {
                Button("Удалить профиль и данные", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("spotchat.deleteProfile")
            } footer: {
                Text("Удаляет профиль, ключи, контакты, историю и очередь на этом iPhone. Восстановить прежний профиль будет нельзя. Копии у других людей не удаляются.")
            }
        }
        .fontWeight(.regular)
        .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
        .alert(
            NSLocalizedString("local.delete.title", comment: ""),
            isPresented: $confirmDelete
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                NSLocalizedString("local.delete.action", comment: ""),
                role: .destructive
            ) {
                runtime.deleteProfileHandler?()
            }
        } message: {
            Text(NSLocalizedString("local.delete.message", comment: ""))
        }
        .alert("Shum", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Понятно") {} } message: { Text(error ?? "") }
    }
}

struct SpotchatContactActionsMenu: View {
    @ObservedObject var runtime: SpotchatRuntime
    let card: SpotchatContactCard
    var onDelete: () -> Void = {}
    @State private var action: String?
    @State private var error: String?
    private var blocked: Bool { runtime.permanent?.isBlocked(card) == true }
    var body: some View {
        Menu {
            if blocked {
                Button { action = "block" } label: {
                    Label("Разблокировать", systemImage: "hand.raised.slash")
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
            } else {
                Button(role: .destructive) { action = "block" } label: {
                    Label("Заблокировать", systemImage: "hand.raised")
                        .foregroundStyle(.red)
                }
                .tint(.red)
            }
            Button { action = "chat" } label: {
                Label("Удалить чат", systemImage: "trash")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
            Button { action = "contact" } label: {
                Label("Удалить контакт", systemImage: "person.crop.circle.badge.minus")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
        } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44).contentShape(Circle()) }
        .accessibilityLabel("Действия с контактом")
        .confirmationDialog(title, isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            if let action {
                Button(title, role: blocked && action == "block" ? nil : .destructive) {
                    do {
                        if action == "block" { try runtime.permanent?.setBlocked(card, blocked: !blocked) }
                        else { try runtime.permanent?.deleteConversation(with: card, removeContact: action == "contact"); onDelete() }
                    } catch { self.error = error.localizedDescription }
                    self.action = nil
                }
            }
            Button("Отмена", role: .cancel) { action = nil }
        } message: {
            Text(action == "block" ? (blocked ? "Вы снова сможете обмениваться сообщениями." : "Сообщения и приглашения этого пользователя будут отклоняться на вашем iPhone. Неотправленные сообщения будут отменены.") : (action == "contact" ? "Контакт, история и очередь будут удалены на этом iPhone. Копии у собеседника и существующая блокировка сохранятся." : "История и очередь будут удалены на этом iPhone. Контакт сохранится, и вы сможете начать новый разговор."))
        }
        .alert("Shum", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Понятно") {} } message: { Text(error ?? "") }
    }
    private var title: String {
        switch action { case "block": return blocked ? "Разблокировать контакт" : "Заблокировать контакт"
        case "contact": return "Удалить контакт"; default: return "Удалить чат" }
    }
}
#endif
