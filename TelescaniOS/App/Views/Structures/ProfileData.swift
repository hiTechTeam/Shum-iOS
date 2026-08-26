import SwiftUI

struct ProfileDataView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var authCodeViewModel: CodeViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    @State private var showScanningSettings = false
    @State private var showInfoSheet = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
    @State private var showLogoutConfirmation = false
    @State private var showLogoutError = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var showNameEditor = false
    @State private var showBioEditor = false
    @State private var showTelegramLink = false
    @State private var draftBio = ""
    @State private var isWorking = false

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
        normalized(authCodeViewModel.bio)
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
        draftBio = authCodeViewModel.bio ?? ""
        authCodeViewModel.resetBioSaveState()
        showBioEditor = true
    }

    private func openTelegramLink() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        authCodeViewModel.resetCodeEntry()
        showTelegramLink = true
    }

    private var profileActionsMenu: some View {
        Menu {
            Button {
                showScanningSettings = true
            } label: {
                Label(
                    Inc.Scanning.scanning.localized,
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)

            Button {
                showInfoSheet = true
            } label: {
                Label(
                    Inc.Info.title.localized,
                    systemImage: "info.circle"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)

            Button {
                showBlockedProfiles = true
            } label: {
                Label(
                    Inc.NearbyProfile.blockedMenu.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)

            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showLogoutOptions = true
            } label: {
                Label(
                    Inc.Profile.logout.localized,
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
                .foregroundStyle(.red)
            }
            .tint(.red)
            .disabled(isWorking)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Inc.Profile.moreActions.localized)
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

    private func logoutCurrent() {
        isWorking = true
        Task {
            do {
                try await coordinator.logoutCurrentSession()
            } catch {
                isWorking = false
                showLogoutError = true
            }
        }
    }

    private func deleteAccount() {
        isWorking = true
        Task {
            do {
                try await coordinator.deleteAccount()
            } catch {
                isWorking = false
                showDeleteError = true
            }
        }
    }

    var body: some View {
        ZStack {
            Color.tsBackground.ignoresSafeArea()
            scrollContent
        }
        .onChange(of: authCodeViewModel.photoS3URL) { _, value in
            photoVM.loadPhotoFromURL(value)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                profileActionsMenu
            }
        }
        .sheet(isPresented: $showScanningSettings) {
            ScanningSettingsSheet()
                .environmentObject(coordinator)
                .environmentObject(coordinator.peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBlockedProfiles) {
            BlockedProfilesView()
                .environmentObject(coordinator.peopleViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNameEditor) {
            ProfileNameEditorSheet(authVM: authCodeViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBioEditor) {
            BioEditorSheet(
                draftBio: $draftBio,
                isPresented: $showBioEditor,
                authVM: authCodeViewModel
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(authCodeViewModel.isSavingBio)
        }
        .sheet(isPresented: $showTelegramLink) {
            TelegramLinkProfileSheet(authVM: authCodeViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(
            Inc.Profile.accountActionsTitle.localized,
            isPresented: $showLogoutOptions
        ) {
            Button(Inc.Profile.logoutCurrent.localized, role: .destructive) {
                DispatchQueue.main.async {
                    showLogoutConfirmation = true
                }
            }
            Button(Inc.Profile.deleteAccount.localized, role: .destructive) {
                DispatchQueue.main.async {
                    showDeleteConfirmation = true
                }
            }
            Button(Inc.Common.cancel.localized, role: .cancel) { }
        }
        .alert(
            Inc.Profile.logoutCurrentTitle.localized,
            isPresented: $showLogoutConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                Inc.Profile.logoutCurrent.localized,
                role: .destructive,
                action: logoutCurrent
            )
        } message: {
            Text(Inc.Profile.logoutCurrentMessage.localized)
        }
        .alert(Inc.Profile.logoutFailed.localized, isPresented: $showLogoutError) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        }
        .alert(
            Inc.Profile.deleteAccountTitle.localized,
            isPresented: $showDeleteConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                Inc.Profile.deleteAccount.localized,
                role: .destructive,
                action: deleteAccount
            )
        } message: {
            Text(Inc.Profile.deleteAccountMessage.localized)
        }
        .alert(Inc.Profile.deleteAccountFailed.localized, isPresented: $showDeleteError) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        } message: {
            Text(Inc.Profile.deleteAccountFailedMessage.localized)
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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.cancel.localized) {
                        dismiss()
                    }
                    .frame(width: 92, alignment: .leading)
                }

                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.nameTitle.localized)
                        .font(.headline)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Profile.saveName.localized, action: save)
                        .frame(width: 92, alignment: .trailing)
                        .fontWeight(.semibold)
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

                RegistrationPrimaryButton(
                    title: linkButtonTitle,
                    isEnabled: authVM.codeStatus == true
                        && !authVM.isLoading,
                    accentColor: .blue,
                    action: confirmTelegramCode
                )
                .frame(maxWidth: 360)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.cancel.localized) {
                        dismiss()
                    }
                    .frame(width: 92, alignment: .leading)
                }

                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.telegramTitle.localized)
                        .font(.headline)
                }

                ToolbarItem(placement: .confirmationAction) {
                    BotButton()
                }
            }
        }
        .onAppear {
            authVM.resetCodeEntry()
        }
    }

    private var linkButtonTitle: String {
        authVM.codeStatus == true
            ? Inc.Profile.linkTelegram.localized
            : Inc.Onboarding.confirmButton.localized
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

private struct ScanningSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showBluetoothAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(Inc.Scanning.scanToggleDescription.localized)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
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
            .navigationTitle(Inc.Scanning.scanning.localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
