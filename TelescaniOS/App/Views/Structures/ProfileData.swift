import SwiftUI

struct ProfileDataView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var authCodeViewModel: LocalProfileViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    @State private var showBioEditor = false
    @State private var profileEditor: LocalCardDetailsMode?
    @State private var draftBio = ""

    init(
        authCodeViewModel: LocalProfileViewModel,
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
            ProfileInformationRow(title: NSLocalizedString("local.profile.name", comment: ""),
                value: authCodeViewModel.tgName ?? "—", showsAccentValue: false,
                position: .top, action: { profileEditor = .name })
            profileRowDivider
            ProfileInformationRow(
                title: Inc.Profile.telegramTitle.localized,
                value: displayTelegram,
                showsAccentValue: telegramUsername == nil,
                position: .middle,
                action: openTelegramLink
            )

            profileRowDivider

            ProfileInformationRow(
                title: Inc.Profile.informationTitle.localized,
                value: displayBio,
                showsAccentValue: false,
                position: .bottom,
                action: openBioEditor
            )
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .padding(.horizontal, 20)
    }

    private var profileRowDivider: some View {
        Divider()
            .padding(.leading, 20)
            .padding(.trailing, 20)
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

    private func openBioEditor() {
        draftBio = String((authCodeViewModel.bio ?? "").prefix(36))
        authCodeViewModel.resetBioSaveState()
        showBioEditor = true
    }

    private func openTelegramLink() {
        profileEditor = .telegram
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileSection
            }
            .padding(.bottom, 32)
        }
        .telescanAlwaysBounce()
        .refreshable { await coordinator.refreshSession() }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            scrollContent
        }
        .telescanOnChange(of: authCodeViewModel.localPhotoURL) { _, value in
            photoVM.loadPhotoFromURL(value)
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
        .sheet(item: $profileEditor) { mode in
            NavigationStack {
                LocalCardDetailsView(profile: authCodeViewModel, photo: photoVM, mode: mode) {
                    profileEditor = nil
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ProfileInformationRow: View {
    let title: String
    let value: String
    let showsAccentValue: Bool
    let position: ProfileMenuRowPosition
    let action: () -> Void

    var body: some View {
        ProfileMenuButton(position: position, action: action) {
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
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }
}

struct ScanningSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showBluetoothAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        Inc.Scanning.scanning.localized,
                        isOn: scanningBinding
                    )
                } header: {
                    Text(Inc.Scanning.scanToggleDescription.localized)
                        .telescanDescriptionStyle()
                        .textCase(nil)
                }
            }
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
