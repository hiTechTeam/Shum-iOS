import SwiftUI

struct AuthCode: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var authCodeViewModel: CodeViewModel
    @State private var accountAlert: AccountAlert?
    @State private var isPerformingAccountAction = false
    
    var body: some View {
        ZStack {
            
            Color.tsBackground
                .ignoresSafeArea()
            
            VStack {
                ScrollView {
                    CodeSpace()
                    Color.clear.frame(height: 8)
                }
                
                NextButton(codeStatus: $authCodeViewModel.codeStatus) {
                    Task {
                        if await authCodeViewModel.confirmCode() {
                            coordinator.completedRegistration()
                        }
                    }
                }
                
            }
            .disabled(isPerformingAccountAction)
            .overlay {
                if isPerformingAccountAction {
                    ProgressView()
                        .padding(16)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button(Inc.Profile.logoutCurrent.localized) {
                            accountAlert = .logoutConfirmation
                        }
                        Button(
                            Inc.Profile.deleteAccount.localized,
                            role: .destructive
                        ) {
                            accountAlert = .deleteConfirmation
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
            .alert(item: $accountAlert) { alert in
                makeAlert(alert)
            }
        }
    }

    private func performAccountAction(
        failureTitle: String,
        failureMessage: String,
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAccountAction else { return }
        Task { @MainActor in
            isPerformingAccountAction = true
            defer { isPerformingAccountAction = false }
            do {
                try await action()
            } catch {
                accountAlert = .failure(
                    title: failureTitle,
                    message: failureMessage
                )
            }
        }
    }

    private func makeAlert(_ alert: AccountAlert) -> Alert {
        switch alert {
        case .logoutConfirmation:
            return Alert(
                title: Text(Inc.Profile.logoutCurrentTitle.localized),
                message: Text(Inc.Profile.logoutCurrentMessage.localized),
                primaryButton: .destructive(
                    Text(Inc.Profile.logoutCurrent.localized)
                ) {
                    performAccountAction(
                        failureTitle: Inc.Profile.logoutFailed.localized,
                        failureMessage: Inc.Profile.logoutFailed.localized
                    ) {
                        try await coordinator.logoutCurrentSession()
                    }
                },
                secondaryButton: .cancel(Text(Inc.Common.cancel.localized))
            )
        case .deleteConfirmation:
            return Alert(
                title: Text(Inc.Profile.deleteAccountTitle.localized),
                message: Text(Inc.Profile.deleteAccountMessage.localized),
                primaryButton: .destructive(
                    Text(Inc.Profile.deleteAccount.localized)
                ) {
                    performAccountAction(
                        failureTitle: Inc.Profile.deleteAccountFailed.localized,
                        failureMessage: Inc.Profile.deleteAccountFailedMessage.localized
                    ) {
                        try await coordinator.deleteAccount()
                    }
                },
                secondaryButton: .cancel(Text(Inc.Common.cancel.localized))
            )
        case .failure(let title, let message):
            return Alert(
                title: Text(title),
                message: Text(message),
                dismissButton: .cancel(Text(Inc.Common.okey.localized))
            )
        }
    }
}

private enum AccountAlert: Identifiable {
    case logoutConfirmation
    case deleteConfirmation
    case failure(title: String, message: String)

    var id: String {
        switch self {
        case .logoutConfirmation:
            return "logout"
        case .deleteConfirmation:
            return "delete"
        case .failure(let title, _):
            return "failure-\(title)"
        }
    }
}
