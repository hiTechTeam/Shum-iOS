import SwiftUI
import UniformTypeIdentifiers

struct ShumBackupCreateView: View {
    var onCreated: (Date) -> Void = { _ in }

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isPreparing = false
    @State private var isChoosingDestination = false
    @State private var preparedFile: URL?
    @State private var didSaveFile = false
    @State private var showsProgress = false
    @State private var progress: ShumBackupProgressState = .working
    @State private var completedAt: Date?

    private var validPassword: Bool {
        password.count >= ShumBackupService.minimumPasswordLength
            && password.utf8.count <= 256
    }

    var body: some View {
        Group {
            if showsProgress {
                ShumBackupProgressView(operation: .create, state: progress) {
                    showsProgress = false
                    if let completedAt {
                        onCreated(completedAt)
                        self.completedAt = nil
                    }
                }
                .toolbar(.hidden, for: .navigationBar, .tabBar)
                .navigationBarBackButtonHidden()
                .task {
                    guard progress.isWorking else { return }
                    // Start the minimum animation time when its view appears,
                    // after the system Save sheet has finished dismissing.
                    await ShumBackupProgressState.finishAnimation(since: .now)
                    guard !Task.isCancelled else { return }
                    progress = .success
                }
            } else {
                backupForm
            }
        }
        .interactiveDismissDisabled(isPreparing || showsProgress)
        .sheet(isPresented: $isChoosingDestination, onDismiss: {
            if let preparedFile {
                try? FileManager.default.removeItem(at: preparedFile.deletingLastPathComponent())
            }
            preparedFile = nil
            if didSaveFile { finishSaving() }
        }) {
            if let preparedFile {
                ShumBackupSavePicker(file: preparedFile) { saved in
                    didSaveFile = saved
                    isChoosingDestination = false
                }
            }
        }
    }

    private var backupForm: some View {
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
                Button(action: prepareBackup) {
                    HStack {
                        Spacer()
                        if isPreparing {
                            ProgressView()
                            Text("Подготавливаем файл…")
                        } else {
                            Text("Создать резервную копию")
                        }
                        Spacer()
                    }
                }
                .disabled(!validPassword || confirmation != password || isPreparing || showsProgress)
            }
        }
        .shumGroupedScreenBackground()
        .fontWeight(.regular)
        .navigationTitle("Резервная копия")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPreparing)
    }

    private func backupItem(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
        }
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Shum-\(formatter.string(from: Date())).shumbackup"
    }

    private func prepareBackup() {
        guard validPassword, password == confirmation, !isPreparing, !showsProgress else { return }
        isPreparing = true
        didSaveFile = false
        completedAt = nil
        let backupPassword = password
        let filename = defaultFilename
        Task { @MainActor in
            do {
                let data = try await ShumBackupService.shared.create(password: backupPassword)
                preparedFile = try await Task.detached(priority: .userInitiated) {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ShumBackup-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    do {
                        return try ShumBackupFileWriter.save(data, in: folder, filename: filename)
                    } catch {
                        try? FileManager.default.removeItem(at: folder)
                        throw error
                    }
                }.value
                isPreparing = false
                isChoosingDestination = true
            } catch {
                isPreparing = false
                progress = .failure(error.localizedDescription)
                showsProgress = true
            }
        }
    }

    private func finishSaving() {
        // Export completion is the only success signal; opening or cancelling
        // the destination picker must never record a completed backup.
        didSaveFile = false
        let date = Date()
        UserDefaults.standard.set(
            date.timeIntervalSince1970,
            forKey: ShumBackupService.lastBackupDateKey
        )
        password = ""
        confirmation = ""
        completedAt = date
        progress = .working
        showsProgress = true
    }
}

/// Export mode provides the system Save action, destination and filename UI.
/// Only an already encrypted file is handed to the system document picker.
private struct ShumBackupSavePicker: UIViewControllerRepresentable {
    let file: URL
    let onSaved: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSaved: onSaved) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        picker.title = "Сохранить резервную копию"
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSaved: (Bool) -> Void
        init(onSaved: @escaping (Bool) -> Void) { self.onSaved = onSaved }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onSaved(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onSaved(false)
        }
    }
}

struct ShumBackupRestoreView: View {
    let data: Data
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var password = ""
    @State private var showsProgress = false
    @State private var progress: ShumBackupProgressState = .working
    @State private var hasInstalledBackup = false

    private var metadata: ShumBackupMetadata? {
        try? ShumBackupService.shared.metadata(for: data)
    }

    var body: some View {
        NavigationStack {
            if showsProgress {
                ShumBackupProgressView(operation: .restore, state: progress) {
                    if case .success = progress {
                        onRestored()
                    } else if hasInstalledBackup {
                        restore()
                    } else {
                        showsProgress = false
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            } else {
                restoreForm
            }
        }
        .interactiveDismissDisabled(showsProgress)
    }

    private var restoreForm: some View {
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
                        Text("Восстановить профиль")
                        Spacer()
                    }
                }
                .disabled(
                    password.count < ShumBackupService.minimumPasswordLength
                        || metadata == nil
                )
            }
        }
        .shumGroupedScreenBackground()
        .fontWeight(.regular)
        .navigationTitle("Восстановление")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { dismiss() }
            }
        }
    }

    private func restore() {
        guard password.count >= ShumBackupService.minimumPasswordLength,
              metadata != nil else { return }
        if showsProgress, case .working = progress { return }
        progress = .working
        showsProgress = true
        let backupPassword = password
        Task { @MainActor in
            let startedAt = ContinuousClock.now
            let result: ShumBackupProgressState
            do {
                // If installing succeeded but opening the profile failed, retry
                // that last step without attempting to overwrite the profile.
                if !hasInstalledBackup {
                    _ = try await ShumBackupService.shared.restore(
                        data: data,
                        password: backupPassword
                    )
                    hasInstalledBackup = true
                }
                guard coordinator.prepareRestoredProfileForSecurity() else {
                    throw ShumBackupError.couldNotSave
                }
                password = ""
                result = .success
            } catch {
                result = .failure(error.localizedDescription)
            }
            await ShumBackupProgressState.finishAnimation(since: startedAt)
            progress = result
        }
    }
}

enum ShumBackupProgressState {
    case working
    case success
    case failure(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    static func finishAnimation(since startedAt: ContinuousClock.Instant) async {
        let elapsed = startedAt.duration(to: .now)
        if elapsed < .milliseconds(1_250) {
            try? await Task.sleep(for: .milliseconds(1_250) - elapsed)
        }
    }
}

private struct ShumBackupProgressView: View {
    enum Operation { case create, restore }

    @Environment(\.shumThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let operation: Operation
    let state: ShumBackupProgressState
    let onContinue: () -> Void
    @State private var startedAt = Date()

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            VStack(spacing: 18) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !state.isWorking)) { timeline in
                    let time = timeline.date.timeIntervalSince(startedAt)
                    ZStack {
                        ShumOnboardingPixelIllustration(kind: illustrationKind)
                            .foregroundStyle(illustrationColor)
                            .frame(width: 112, height: 92)

                        ForEach(0..<(state.isWorking ? 14 : 0), id: \.self) { index in
                            let phase = (time * 0.85 + Double(index) / 14).truncatingRemainder(dividingBy: 1)
                            let x = CGFloat(operation == .create ? 1 - phase : phase)
                            let lane = CGFloat(index % 7 - 3) * 14
                            Rectangle()
                                .fill(palette.accent.opacity(0.8))
                                .frame(width: 8, height: 8)
                                .offset(x: (x - 0.5) * 240, y: lane)
                                .opacity(reduceMotion ? 0 : sin(phase * .pi))
                        }
                    }
                    .frame(width: 280, height: 160)
                }
                .accessibilityHidden(true)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)

                if !state.isWorking {
                    RegistrationPrimaryButton(title: buttonTitle, action: onContinue)
                        .frame(maxWidth: 330)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var title: String {
        switch state {
        case .working:
            return operation == .create ? "Завершаем сохранение" : "Восстанавливаем профиль"
        case .success:
            return operation == .create ? "Резервная копия создана" : "Резервная копия восстановлена"
        case .failure:
            return operation == .create ? "Не удалось создать копию" : "Не удалось восстановить копию"
        }
    }

    private var detail: String {
        switch state {
        case .working:
            return operation == .create
                ? "Резервная копия зашифрована и сохранена в выбранную папку."
                : "Проверяем пароль и возвращаем ключи и переписку на устройство."
        case .success:
            return operation == .create
                ? "Файл сохранён в выбранную папку. Храните его и пароль отдельно."
                : "Профиль и переписка восстановлены. Продолжите, чтобы настроить код Shum на этом устройстве."
        case .failure(let message):
            return message
        }
    }

    private var illustrationKind: ShumOnboardingPixelIllustration.Kind {
        switch state {
        case .working: return .security
        case .success: return .success
        case .failure: return .failure
        }
    }

    private var illustrationColor: Color {
        if case .failure = state { return .gray }
        return palette.accent
    }

    private var buttonTitle: String {
        if operation == .create, case .success = state { return "Отлично" }
        return "Продолжить"
    }
}
