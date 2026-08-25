import SwiftUI

struct AuthCode: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var authCodeViewModel: CodeViewModel
    @State private var goNext: Bool = false
    @State private var showDeleteConfirmation = false
    @State private var accountActionFailed = false
    @State private var isPerformingAccountAction = false
    
    var body: some View {
        ZStack {
            
            Color.tsBackground
                .ignoresSafeArea()
            
            VStack {
                ScrollView {
                    CodeSpace()
                    Color.clear.frame(width: 390, height: 8)
                }
                
                NextButton(codeStatus: $authCodeViewModel.codeStatus) {
                    Task {
                        if await authCodeViewModel.confirmCode() {
                            goNext = true
                        }
                    }
                }
                
            }
            .navigationDestination(isPresented: $goNext) {
                ScanToggleView()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(Inc.Profile.logoutCurrent.localized) {
                            performAccountAction {
                                try await coordinator.logoutCurrentSession()
                            }
                        }
                        Button(
                            Inc.Profile.deleteAccount.localized,
                            role: .destructive
                        ) {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isPerformingAccountAction)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    BotButton()
                }
            }
            .navigationTitle(Inc.Registration.telegramLinkTitle.localized)
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                Inc.Profile.deleteAccountTitle.localized,
                isPresented: $showDeleteConfirmation
            ) {
                Button(Inc.Common.cancel.localized, role: .cancel) {}
                Button(Inc.Profile.deleteAccount.localized, role: .destructive) {
                    performAccountAction {
                        try await coordinator.deleteAccount()
                    }
                }
            } message: {
                Text(Inc.Profile.deleteAccountMessage.localized)
            }
            .alert(
                Inc.Profile.deleteAccountFailed.localized,
                isPresented: $accountActionFailed
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Inc.Profile.deleteAccountFailedMessage.localized)
            }
        }
    }

    private func performAccountAction(
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAccountAction else { return }
        Task { @MainActor in
            isPerformingAccountAction = true
            defer { isPerformingAccountAction = false }
            do {
                try await action()
            } catch {
                accountActionFailed = true
            }
        }
    }
}
