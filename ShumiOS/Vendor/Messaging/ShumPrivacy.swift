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

struct ShumPrivacySettings: View {
    @ObservedObject var runtime: ShumRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    var body: some View {
        List {
            Section {
                Button("Удалить профиль и данные", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("shum.deleteProfile")
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
                // Close the settings sheet before replacing the registered
                // app hierarchy. Otherwise SwiftUI can retain its presentation
                // host over the newly-created registration screen.
                dismiss()
                Task { @MainActor in
                    await Task.yield()
                    runtime.deleteProfileHandler?()
                }
            }
        } message: {
            Text(NSLocalizedString("local.delete.message", comment: ""))
        }
    }
}

struct ShumContactActionsMenu: View {
    @ObservedObject var runtime: ShumRuntime
    let card: ShumContactCard
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
                Label("Убрать из контактов", systemImage: "person.crop.circle.badge.minus")
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
                        else if action == "contact" {
                            try runtime.permanent?.removeFromContacts(card)
                            onDelete()
                        } else {
                            try runtime.permanent?.deleteConversation(with: card)
                            onDelete()
                        }
                    } catch { self.error = error.localizedDescription }
                    self.action = nil
                }
            }
            Button("Отмена", role: .cancel) { action = nil }
        } message: {
            Text(action == "block" ? (blocked ? "Вы снова сможете обмениваться сообщениями." : "Сообщения и приглашения этого пользователя будут отклоняться на вашем iPhone. Неотправленные сообщения будут отменены.") : (action == "contact" ? "Пользователь исчезнет из Контактов. Переписка и возможность общения сохранятся." : "История и очередь будут удалены на этом iPhone. Контакт сохранится, и вы сможете начать новый разговор."))
        }
        .alert("Shum", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Понятно") {} } message: { Text(error ?? "") }
    }
    private var title: String {
        switch action { case "block": return blocked ? "Разблокировать контакт" : "Заблокировать контакт"
        case "contact": return "Убрать из контактов"; default: return "Удалить чат" }
    }
}
#endif
