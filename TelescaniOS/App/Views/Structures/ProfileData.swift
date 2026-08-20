import SwiftUI

struct ProfileDataView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.openURL) private var openURL
    @ObservedObject var authCodeViewModel: CodeViewModel
    @StateObject private var photoVM = ProfilePhotoViewModel()
    @State private var showInfoSheet = false
    @State private var showDeveloperLinks = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
    @State private var showLogoutConfirmation = false
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
            BioProfileField(authVM: authCodeViewModel)
            ScanToggle(isScaning: $coordinator.isScaning)
        }
        .frame(maxWidth: .infinity)
    }

    private var productDescription: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showDeveloperLinks = true
        } label: {
            Text(Inc.Profile.creatorCredit.localized)
                .font(.system(size: 12))
                .foregroundStyle(.blue)
                .frame(width: 280)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.plain)
        .padding(.top, 40)
    }

    private var profileActionsMenu: some View {
        Menu {
            Button {
                showInfoSheet = true
            } label: {
                Label(
                    Inc.Info.title.localized,
                    systemImage: "info.circle"
                )
            }

            Button {
                showBlockedProfiles = true
            } label: {
                Label(
                    Inc.NearbyProfile.blockedMenu.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }

            Divider()

            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showLogoutOptions = true
            } label: {
                Label(
                    Inc.Profile.logout.localized,
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
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
                productDescription
            }
            .padding(.bottom, 32)
        }
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

    private func openDeveloperLink(_ address: String) {
        guard let url = URL(string: address) else { return }
        openURL(url)
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
        .alert(
            Inc.Profile.developerLinksTitle.localized,
            isPresented: $showDeveloperLinks
        ) {
            Button("GitHub") {
                openDeveloperLink("https://github.com/r66cha")
            }
            Button(Inc.Profile.telegramChannel.localized) {
                openDeveloperLink("https://t.me/r_chukavin")
            }
            Button(Inc.Common.cancel.localized, role: .cancel) { }
        } message: {
            Text(Inc.Profile.developerLinksMessage.localized)
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
