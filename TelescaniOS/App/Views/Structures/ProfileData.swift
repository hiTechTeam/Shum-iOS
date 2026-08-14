import SwiftUI

struct ProfileDataView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var authCodeViewModel: CodeViewModel
    @StateObject private var photoVM = ProfilePhotoViewModel()
    @State private var showLogoutOptions = false
    @State private var showLogoutAllSent = false
    @State private var showLogoutError = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var isWorking = false

    init(authCodeViewModel: CodeViewModel) {
        self.authCodeViewModel = authCodeViewModel
    }

    private var headerInfo: some View {
        VStack(spacing: 8) {
            Text(Inc.Registration.tgUsername.localized)
                .font(.system(size: 12))
                .frame(width: 350, alignment: .leading)

            UsernamePlaceholderProfile(authVM: authCodeViewModel)
        }
    }

    private var profileSection: some View {
        VStack(spacing: 16) {
            ProfilePhotoView(viewModel: photoVM)
            headerInfo
            ScanToggle(isScaning: $coordinator.isScaning)
        }
        .frame(maxWidth: .infinity)
    }

    private var productDescription: some View {
        VStack(spacing: 4) {
            Text(Inc.Profile.telescanTelegramExtension.localized)
                .font(.system(size: 12))
            Text(Inc.Profile.poweredByBluetooth.localized)
                .font(.system(size: 11))
                .opacity(0.7)
        }
        .foregroundColor(.gray)
        .frame(width: 280)
        .multilineTextAlignment(.center)
        .padding(.top, 40)
    }

    private var logoutButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showLogoutOptions = true
        } label: {
            Group {
                if isWorking {
                    ProgressView()
                } else {
                    Text(Inc.Profile.logout.localized)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(actionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .padding(.horizontal, 16)
    }

    private var deleteAccountButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showDeleteConfirmation = true
        } label: {
            Text(Inc.Profile.deleteAccount.localized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(actionBackground)
                .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var actionBackground: Color {
        colorScheme == .dark ? Color.gray.opacity(0.35) : .white
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileSection
                productDescription
                logoutButton.padding(.top, 40)
                deleteAccountButton
            }
        }
        .refreshable { await authCodeViewModel.refreshProfile() }
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

    private func logoutAll() {
        isWorking = true
        Task {
            do {
                try await coordinator.requestLogoutAll()
                isWorking = false
                showLogoutAllSent = true
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
        .alert(
            Inc.Profile.logoutTitle.localized,
            isPresented: $showLogoutOptions
        ) {
            Button(Inc.Profile.logoutCurrent.localized, action: logoutCurrent)
            Button(Inc.Profile.logoutAll.localized, role: .destructive, action: logoutAll)
            Button(Inc.Common.cancel.localized, role: .cancel) { }
        }
        .alert(Inc.Profile.logoutAllSent.localized, isPresented: $showLogoutAllSent) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        } message: {
            Text(Inc.Profile.logoutAllSentMessage.localized)
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
