import SwiftUI

struct ShumSecuritySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var runtime: ShumRuntime
    @ObservedObject private var appLock = ShumAppLock.shared
    let fingerprint: String?

    @State private var isWorking = false
    @State private var showChangeCode = false
    @State private var showBlockedProfiles = false
    @State private var confirmDelete = false
    @State private var lastBackupDate: Date? = {
        let value = UserDefaults.standard.double(
            forKey: ShumBackupService.lastBackupDateKey
        )
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }()

    var body: some View {
        List {
            Section {
                securityMethodRow(
                    title: appLock.biometricTitle,
                    subtitle: "Системная биометрия устройства".localized,
                    systemImage: "faceid",
                    selected: appLock.preferredMethod == .biometrics
                        && appLock.isBiometricsEnabled,
                    action: selectBiometrics
                )

                securityMethodRow(
                    title: "Код Shum".localized,
                    subtitle: appLock.hasPasscode ? "Пять цифр".localized : "Код не создан".localized,
                    systemImage: "number.square",
                    selected: appLock.preferredMethod == .passcode,
                    action: selectPasscode
                )

                securityMethodRow(
                    title: "Без проверки".localized,
                    subtitle: "Открывать Shum сразу".localized,
                    systemImage: "lock.open",
                    selected: appLock.preferredMethod == .none,
                    action: appLock.useNoVerification
                )

                Button {
                    showChangeCode = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .frame(width: 24)
                            .foregroundStyle(.primary)
                        Text(appLock.hasPasscode ? "Изменить код".localized : "Создать код".localized)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Способ входа".localized)
            } footer: {
                Text("Face ID используется автоматически. Код Shum можно выбрать основным или использовать, если биометрия недоступна. Без проверки открывает приложение сразу.".localized)
            }

            Section("Ключи профиля".localized) {
                LabeledContent("Хранилище".localized, value: "Это устройство".localized)

                if let fingerprint {
                    LabeledContent("Отпечаток".localized) {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                NavigationLink {
                    ShumBackupCreateView { date in
                        lastBackupDate = date
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Создать резервную копию".localized)
                                .foregroundStyle(.primary)
                            Text(backupStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "externaldrive.badge.plus")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Color.primary)
                    }
                }
            } header: {
                Text("Восстановление".localized)
            } footer: {
                Text("Копия хранится только там, куда вы её сохраните. Для восстановления понадобятся файл и его пароль.".localized)
            }

            Section("Конфиденциальность".localized) {
                Button {
                    showBlockedProfiles = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .frame(width: 24)
                        Text("Заблокированные".localized)
                        Spacer()
                        Text(String(runtime.permanent?.state.blocked?.count ?? 0))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            Section {
                Button("Удалить профиль и данные".localized, role: .destructive) {
                    confirmDelete = true
                }
                .accessibilityIdentifier("shum.deleteProfile")
            } footer: {
                Text("Удаляет профиль, ключи, контакты, историю и очередь на этом устройстве. Копии у собеседников не удаляются.".localized)
            }

            if let message = appLock.errorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .shumGroupedScreenBackground()
        .fontWeight(.regular)
        .navigationTitle("Безопасность и данные".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBlockedProfiles) {
            BlockedProfilesView(runtime: runtime)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "local.delete.title".localized,
            isPresented: $confirmDelete
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                "local.delete.action".localized,
                role: .destructive
            ) {
                // Release the pushed settings host before registration replaces the app tree.
                dismiss()
                Task { @MainActor in
                    await Task.yield()
                    runtime.deleteProfileHandler?()
                }
            }
        } message: {
            Text("local.delete.message".localized)
        }
        .navigationDestination(isPresented: $showChangeCode) {
            ShumChangePasscodeView()
        }
        .onAppear {
            let value = UserDefaults.standard.double(
                forKey: ShumBackupService.lastBackupDateKey
            )
            lastBackupDate = value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
    }

    private var backupStatus: String {
        guard let lastBackupDate else { return "Копия ещё не создана".localized }
        return String.localizedFormat("Последняя: %@".localized, lastBackupDate.formatted(date: .abbreviated, time: .shortened))
    }

    private func securityMethodRow(
        title: String,
        subtitle: String,
        systemImage: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isWorking && systemImage == "faceid" {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func selectBiometrics() {
        guard !isWorking else { return }
        if appLock.isBiometricsEnabled {
            appLock.useBiometricsByDefault()
            return
        }

        isWorking = true
        Task {
            _ = await appLock.enable()
            isWorking = false
        }
    }

    private func selectPasscode() {
        guard !isWorking else { return }
        if appLock.hasPasscode {
            appLock.usePasscodeByDefault()
        } else {
            showChangeCode = true
        }
    }
}

private struct ShumChangePasscodeView: View {
    private enum Phase {
        case current
        case new
        case confirm
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLock = ShumAppLock.shared
    @State private var phase: Phase
    @State private var code = ""
    @State private var newCode = ""
    @State private var message: String?
    @State private var isWorking = false

    init() {
        _phase = State(initialValue: ShumAppLock.shared.hasPasscode ? .current : .new)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "key.horizontal")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.top, 28)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)

            ShumPasscodeInput(code: $code)
                .padding(.top, 30)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }

            Spacer()

            RegistrationPrimaryButton(
                title: phase == .confirm ? "Сохранить код".localized : "Продолжить".localized,
                isEnabled: code.count == 5 && !isWorking,
                accentColor: Color.accentColor,
                action: continueFlow
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle("Код Shum".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch phase {
        case .current: return "Введите текущий код".localized
        case .new: return "Создайте новый код".localized
        case .confirm: return "Повторите новый код".localized
        }
    }

    private var description: String {
        phase == .current
            ? "Это подтверждает, что настройки меняете вы.".localized
            : "Код должен состоять из пяти цифр.".localized
    }

    private func continueFlow() {
        guard code.count == 5, !isWorking else { return }
        message = nil

        switch phase {
        case .current:
            isWorking = true
            Task {
                let verified = await appLock.verifyPasscode(code)
                isWorking = false
                code = ""
                if verified {
                    phase = .new
                } else {
                    message = appLock.errorMessage
                }
            }
        case .new:
            newCode = code
            code = ""
            phase = .confirm
        case .confirm:
            guard code == newCode else {
                code = ""
                message = "Коды не совпадают. Попробуйте ещё раз.".localized
                return
            }
            isWorking = true
            Task {
                let saved = await appLock.setPasscode(code)
                isWorking = false
                if saved {
                    dismiss()
                } else {
                    message = appLock.errorMessage
                }
            }
        }
    }
}
