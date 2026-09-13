import SwiftUI

struct ShumSecuritySettingsView: View {
    @ObservedObject private var appLock = ShumAppLock.shared
    let fingerprint: String?

    @State private var isWorking = false
    @State private var showChangeCode = false
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
                    subtitle: "Системная биометрия устройства",
                    systemImage: "faceid",
                    selected: appLock.preferredMethod == .biometrics
                        && appLock.isBiometricsEnabled,
                    action: selectBiometrics
                )

                securityMethodRow(
                    title: "Код Shum",
                    subtitle: appLock.hasPasscode ? "Пять цифр" : "Код не создан",
                    systemImage: "number.square",
                    selected: appLock.preferredMethod == .passcode,
                    action: selectPasscode
                )

                Button {
                    showChangeCode = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .frame(width: 24)
                            .foregroundStyle(.primary)
                        Text(appLock.hasPasscode ? "Изменить код" : "Создать код")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Способ входа")
            } footer: {
                Text("Face ID используется автоматически. Код Shum можно выбрать основным или использовать, если биометрия недоступна.")
            }

            Section("Ключи профиля") {
                LabeledContent("Хранилище", value: "Это устройство")

                if let fingerprint {
                    LabeledContent("Отпечаток") {
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
                            Text("Создать резервную копию")
                                .foregroundStyle(.primary)
                            Text(backupStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "externaldrive.badge.plus")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Восстановление")
            } footer: {
                Text("Копия хранится только там, куда вы её сохраните. Для восстановления понадобятся файл и его пароль.")
            }

            if let message = appLock.errorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
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
        guard let lastBackupDate else { return "Копия ещё не создана" }
        return "Последняя: \(lastBackupDate.formatted(date: .abbreviated, time: .shortened))"
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
                title: phase == .confirm ? "Сохранить код" : "Продолжить",
                isEnabled: code.count == 5 && !isWorking,
                accentColor: Color(uiColor: .systemGreen),
                action: continueFlow
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color("ls-Background").ignoresSafeArea())
        .navigationTitle("Код Shum")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: String {
        switch phase {
        case .current: return "Введите текущий код"
        case .new: return "Создайте новый код"
        case .confirm: return "Повторите новый код"
        }
    }

    private var description: String {
        phase == .current
            ? "Это подтверждает, что настройки меняете вы."
            : "Код должен состоять из пяти цифр."
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
                message = "Коды не совпадают. Попробуйте ещё раз."
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
