import SwiftUI
import UniformTypeIdentifiers

struct ShumBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.shumBackup, .data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ShumBackupError.invalidBackup
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ShumBackupCreateView: View {
    var onCreated: (Date) -> Void = { _ in }

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isCreating = false
    @State private var document: ShumBackupDocument?
    @State private var isExporting = false
    @State private var message: String?
    @State private var showSuccess = false

    private var validPassword: Bool {
        password.count >= ShumBackupService.minimumPasswordLength
            && password.utf8.count <= 256
    }

    var body: some View {
        Form {
            Section {
                SecureField("Пароль резервной копии", text: $password)
                    .textContentType(.newPassword)
                SecureField("Повторите пароль", text: $confirmation)
                    .textContentType(.newPassword)
            } header: {
                Text("Защита копии")
            } footer: {
                Text("Минимум 10 знаков. Этот пароль нигде не хранится, и без него восстановить профиль не получится.")
            }

            Section {
                backupItem("Ключи профиля и Nostr", systemImage: "key.horizontal")
                backupItem("Контакты и настройки", systemImage: "person.2")
                backupItem(
                    "Зашифрованная история чатов",
                    systemImage: "bubble.left.and.bubble.right"
                )
            } header: {
                Text("В резервной копии")
            } footer: {
                Text("Face ID и код Shum привязаны к этому устройству и в копию не входят.")
            }

            Section {
                Button(action: createBackup) {
                    HStack {
                        Spacer()
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Создать резервную копию")
                        }
                        Spacer()
                    }
                }
                .disabled(!validPassword || confirmation != password || isCreating)
            }

            if let message {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Резервная копия")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .shumBackup,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                let date = Date()
                UserDefaults.standard.set(
                    date.timeIntervalSince1970,
                    forKey: ShumBackupService.lastBackupDateKey
                )
                password = ""
                confirmation = ""
                document = nil
                onCreated(date)
                showSuccess = true
            case .failure(let error):
                message = error.localizedDescription
                document = nil
            }
        }
        .alert("Копия создана", isPresented: $showSuccess) {
            Button("Готово", role: .cancel) { }
        } message: {
            Text("Храните файл и пароль отдельно. Shum не сможет восстановить забытый пароль.")
        }
    }

    private func backupItem(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
        }
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Shum-\(formatter.string(from: Date())).shumbackup"
    }

    private func createBackup() {
        guard validPassword, password == confirmation, !isCreating else { return }
        message = nil
        isCreating = true
        let backupPassword = password
        Task {
            do {
                let data = try await ShumBackupService.shared.create(password: backupPassword)
                document = ShumBackupDocument(data: data)
                isCreating = false
                isExporting = true
            } catch {
                isCreating = false
                message = error.localizedDescription
            }
        }
    }
}

struct ShumBackupRestoreView: View {
    let data: Data
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var password = ""
    @State private var isRestoring = false
    @State private var message: String?

    private var metadata: ShumBackupMetadata? {
        try? ShumBackupService.shared.metadata(for: data)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Профиль", value: metadata?.profileName ?? "Неизвестно")
                    if let date = metadata?.createdAt {
                        LabeledContent("Создана") {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Резервная копия Shum")
                }

                Section {
                    SecureField("Пароль резервной копии", text: $password)
                        .textContentType(.password)
                        .onSubmit(restore)
                } footer: {
                    Text("Пароль проверяется только на этом устройстве и никуда не отправляется.")
                }

                Section {
                    Button(action: restore) {
                        HStack {
                            Spacer()
                            if isRestoring {
                                ProgressView()
                            } else {
                                Text("Восстановить профиль")
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        password.count < ShumBackupService.minimumPasswordLength
                            || isRestoring
                            || metadata == nil
                    )
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Восстановление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func restore() {
        guard password.count >= ShumBackupService.minimumPasswordLength,
              !isRestoring else { return }
        message = nil
        isRestoring = true
        let backupPassword = password
        Task {
            do {
                _ = try await ShumBackupService.shared.restore(
                    data: data,
                    password: backupPassword
                )
                guard coordinator.prepareRestoredProfileForSecurity() else {
                    throw ShumBackupError.couldNotSave
                }
                password = ""
                isRestoring = false
                dismiss()
                DispatchQueue.main.async { onRestored() }
            } catch {
                isRestoring = false
                message = error.localizedDescription
            }
        }
    }
}
