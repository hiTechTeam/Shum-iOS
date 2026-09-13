import SwiftUI

struct ShumSecuritySettingsView: View {
    @ObservedObject private var appLock = ShumAppLock.shared
    let fingerprint: String?

    @State private var isWorking = false

    var body: some View {
        List {
            Section {
                Button(action: changeAppLock) {
                    HStack(spacing: 12) {
                        Image(systemName: "faceid")
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(appLock.biometricTitle)
                                .foregroundStyle(.primary)
                            Text(appLock.isEnabled ? "Защита включена" : "Защита выключена")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isWorking {
                            ProgressView()
                        } else if appLock.isEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .disabled(isWorking)
            } header: {
                Text("Доступ к приложению")
            } footer: {
                Text("Биометрия закрывает интерфейс и локальную переписку. Получение зашифрованных сообщений может продолжаться в фоне.")
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
                VStack(alignment: .leading, spacing: 7) {
                    Label("Резервная копия не создана", systemImage: "key.horizontal")
                        .foregroundStyle(.primary)
                    Text("Ключи существуют только на этом устройстве. При его потере прежний профиль и переписку восстановить нельзя.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Восстановление")
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
    }

    private func changeAppLock() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            if appLock.isEnabled {
                _ = await appLock.disable()
            } else {
                _ = await appLock.enable()
            }
            isWorking = false
        }
    }
}
