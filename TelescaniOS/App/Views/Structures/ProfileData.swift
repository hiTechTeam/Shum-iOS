import SwiftUI

struct ProfileDataView: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var authCodeViewModel: CodeViewModel
    @StateObject private var photoVM = ProfilePhotoViewModel()
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var isDeletingAccount = false
    
    init(authCodeViewModel: CodeViewModel) {
        self.authCodeViewModel = authCodeViewModel
    }
    
    private var headerInfo: some View {
        VStack(spacing: 8) {
            HStack {
                Text(Inc.Registration.tgUsername)
                    .font(.system(size: 12))
                    .frame(width: 175, alignment: .leading)
                
                Text(Inc.Registration.currentCode.localized + authCodeViewModel.code)
                    .font(.system(size: 12))
                    .opacity(0.5)
                    .frame(width: 175, alignment: .trailing)
            }
            
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
    
    private var descriptionText: some View {
        Text(Inc.Profile.profileSettingsDescription.localized)
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(width: 280)
            .multilineTextAlignment(.center)
            .padding(.top, 40)
    }
    
    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileSection
                descriptionText
                deleteAccountButton
                    .padding(.top, 40)
            }
        }
    }

    private var deleteAccountButton: some View {
        Button {
            UIImpactFeedbackGenerator(
                style: .medium
            ).impactOccurred()
            showDeleteConfirmation = true
        } label: {
            Group {
                if isDeletingAccount {
                    ProgressView()
                        .tint(.red)
                } else {
                    Text(Inc.Profile.deleteAccount.localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                colorScheme == .dark
                    ? Color.gray.opacity(0.35)
                    : Color.white
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 13)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDeletingAccount)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func deleteAccount() {
        isDeletingAccount = true

        Task {
            do {
                try await coordinator.deleteAccount()
            } catch {
                isDeletingAccount = false
                showDeleteError = true
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()
            scrollContent
        }
        .onChange(of: authCodeViewModel.photoS3URL) { _, newValue in
            photoVM.loadPhotoFromURL(newValue)
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
        .alert(
            Inc.Profile.deleteAccountFailed.localized,
            isPresented: $showDeleteError
        ) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        } message: {
            Text(Inc.Profile.deleteAccountFailedMessage.localized)
        }
    }
}
