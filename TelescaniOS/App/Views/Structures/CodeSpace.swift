import SwiftUI

struct CodeSpace: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var authCodeViewModel: CodeViewModel
    @FocusState private var isCodeFocused: Bool
    
    private var content: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                TitleField(text: Inc.Registration.enterCode.localized)
                CodeField(text: $authCodeViewModel.tmpCode)
                    .focused($isCodeFocused)
                    .onSubmit {
                        isCodeFocused = false
                    }
                    .onTapGesture {
                        isCodeFocused = true
                    }
                    .onChange(of: authCodeViewModel.tmpCode) { _, newValue in
                        guard newValue.count <= 8 else { return }
                        authCodeViewModel.checkCode(newValue.uppercased())
                    }
            }
            VStack(spacing: 4) {
                TitleField(text: Inc.Registration.tgUsername)
                UsernamePlaceholder(
                    username: authCodeViewModel.tmpTgUsername,
                    codeStatus: authCodeViewModel.codeStatus,
                    codeError: authCodeViewModel.codeError,
                    isLoading: authCodeViewModel.isLoading
                )
            }

            Description(text: Inc.Registration.regDescription.localized)
        }
        .padding(.top, 10)
        .frame(maxWidth: 360)
        .padding(.horizontal, 20)
        .onTapGesture {
            isCodeFocused = false
        }
        .onChange(of: authCodeViewModel.codeStatus) { _, status in
            if status == true {
                isCodeFocused = false
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
