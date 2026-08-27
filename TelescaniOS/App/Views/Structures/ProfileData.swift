import SwiftUI

struct ProfileDataView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var authCodeViewModel: CodeViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    @State private var showNameEditor = false
    @State private var showBioEditor = false
    @State private var showTelegramLink = false
    @State private var draftBio = ""

    init(
        authCodeViewModel: CodeViewModel,
        photoViewModel: ProfilePhotoViewModel
    ) {
        self.authCodeViewModel = authCodeViewModel
        self.photoVM = photoViewModel
    }

    private var profileSection: some View {
        VStack(spacing: 34) {
            ProfilePhotoView(viewModel: photoVM)
            profileInformationCard
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private var profileInformationCard: some View {
        VStack(spacing: 0) {
            ProfileInformationRow(
                title: Inc.Profile.nameTitle.localized,
                value: displayName,
                showsAccentValue: false,
                action: openNameEditor
            )

            profileRowDivider

            ProfileInformationRow(
                title: Inc.Profile.informationTitle.localized,
                value: displayBio,
                showsAccentValue: false,
                action: openBioEditor
            )

            profileRowDivider

            ProfileInformationRow(
                title: Inc.Profile.telegramTitle.localized,
                value: displayTelegram,
                showsAccentValue: telegramUsername == nil,
                action: openTelegramLink
            )
        }
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .padding(.horizontal, 20)
    }

    private var profileRowDivider: some View {
        Divider()
            .padding(.leading, 20)
    }

    private var displayName: String {
        normalized(authCodeViewModel.tgName)
            ?? Inc.Profile.notSpecified.localized
    }

    private var displayBio: String {
        normalized(authCodeViewModel.bio).map { String($0.prefix(36)) }
            ?? Inc.Profile.notSpecified.localized
    }

    private var telegramUsername: String? {
        normalized(authCodeViewModel.tgUsername)
    }

    private var displayTelegram: String {
        telegramUsername ?? Inc.Profile.linkTelegram.localized
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openNameEditor() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        showNameEditor = true
    }

    private func openBioEditor() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        draftBio = String((authCodeViewModel.bio ?? "").prefix(36))
        authCodeViewModel.resetBioSaveState()
        showBioEditor = true
    }

    private func openTelegramLink() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        authCodeViewModel.resetCodeEntry()
        showTelegramLink = true
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileSection
            }
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await coordinator.refreshSession() }
    }

    var body: some View {
        ZStack {
            Color.tsBackground.ignoresSafeArea()
            scrollContent
        }
        .onChange(of: authCodeViewModel.photoS3URL) { _, value in
            photoVM.loadPhotoFromURL(value)
        }
        .sheet(isPresented: $showNameEditor) {
            ProfileNameEditorSheet(authVM: authCodeViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBioEditor) {
            BioEditorSheet(
                draftBio: $draftBio,
                isPresented: $showBioEditor,
                authVM: authCodeViewModel
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(authCodeViewModel.isSavingBio)
        }
        .sheet(isPresented: $showTelegramLink) {
            TelegramLinkProfileSheet(authVM: authCodeViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ProfileInformationRow: View {
    let title: String
    let value: String
    let showsAccentValue: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(value)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(
                        showsAccentValue ? Color.accentColor : Color.secondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ProfileNameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var authVM: CodeViewModel
    @State private var draftName: String

    init(authVM: CodeViewModel) {
        self.authVM = authVM
        _draftName = State(initialValue: authVM.tgName ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    Inc.Profile.namePlaceholder.localized,
                    text: $draftName
                )
                .font(.system(size: 16))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .onChange(of: draftName) { _, value in
                    guard value.count > 50 else { return }
                    draftName = String(value.prefix(50))
                }
                .onSubmit(save)

                Text(Inc.Profile.nameDescription.localized)
                    .telescanDescriptionStyle()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(Inc.Common.cancel.localized)
                            .fixedSize()
                            .frame(width: 92, alignment: .leading)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.nameTitle.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Text(Inc.Profile.saveName.localized)
                            .fontWeight(.semibold)
                            .fixedSize()
                            .frame(width: 92, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func save() {
        authVM.updateLocalName(draftName)
        dismiss()
    }
}

private struct TelegramLinkProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var authVM: CodeViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    CodeSpace()
                        .environmentObject(authVM)
                        .padding(.top, 4)
                }
                .scrollBounceBehavior(.basedOnSize)

                Spacer(minLength: 8)

                VStack(spacing: 14) {
                    RegistrationPrimaryButton(
                        title: Inc.Profile.linkTelegram.localized,
                        isEnabled: authVM.codeStatus == true
                            && !authVM.isLoading,
                        accentColor: .blue,
                        action: confirmTelegramCode
                    )
                }
                .frame(maxWidth: 360)
            }
            .padding(.top, 10)
            .padding(.bottom, 16)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.telegramTitle.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    BotButton()
                }
            }
        }
        .onAppear {
            authVM.resetCodeEntry()
        }
        .onDisappear {
            authVM.resetCodeEntry()
        }
    }

    private func confirmTelegramCode() {
        Task {
            guard await authVM.confirmCode() else { return }
            dismiss()

            if let telescanID = authVM.telescanID {
                BLEManager.shared.restartAdvertising(
                    id: telescanID.uuidString.lowercased()
                )
            }
        }
    }

}

struct ScanningSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showBluetoothAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(Inc.Scanning.scanToggleDescription.localized)
                    .telescanDescriptionStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(
                    Inc.Scanning.scanning.localized,
                    isOn: scanningBinding
                )
                .font(.body.weight(.medium))
                .toggleStyle(.switch)
                .tint(.green)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    Color.grOne,
                    in: RoundedRectangle(cornerRadius: 13)
                )

                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.Scanning.scanning.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
            }
            .alert(
                Inc.Alerts.turnOnBLE.localized,
                isPresented: $showBluetoothAlert
            ) {
                Button(Inc.Common.okey.localized, role: .cancel) { }
            }
        }
    }

    private var scanningBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isScaning },
            set: { isScanning in
                guard isScanning != coordinator.isScaning else { return }

                coordinator.setScanning(isScanning)
                UISelectionFeedbackGenerator().selectionChanged()

                if isScanning, !BLEManager.shared.isBluetoothAvailable {
                    showBluetoothAlert = true
                }
            }
        )
    }
}
