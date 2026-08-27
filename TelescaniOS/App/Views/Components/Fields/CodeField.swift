import SwiftUI

struct CodeField: View {
    
    @Binding var text: String
    var isDisabled = false

    @State private var showLimitWarning = false
    @State private var warningTask: Task<Void, Never>?
    
    private let maxLength: Int = 8
    private let fieldHeight: CGFloat = 46
    private let cornerRadius: CGFloat = 13
    private let paddingH: CGFloat = 13
    private let lineWidth: CGFloat = 1
    private let fontSizeCode: CGFloat = 20
    private let generator = UINotificationFeedbackGenerator()
    
    private func handleTextChange(_ newValue: String) {
        let uppercased = newValue.uppercased()
        
        guard uppercased.count <= maxLength else {
            text = String(uppercased.prefix(maxLength))
            showWarning()
            return
        }

        if text != uppercased {
            text = uppercased
        }
    }

    private func showWarning() {
        generator.notificationOccurred(.warning)
        warningTask?.cancel()

        withAnimation(.easeInOut(duration: 0.2)) {
            showLimitWarning = true
        }

        warningTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showLimitWarning = false
            }
        }
    }
    
    private var textField: some View {
        TextField(
            Inc.Registration.codePlaceholder.localized,
            text: $text
        )
        .padding(.leading, paddingH)
        .padding(.trailing, showLimitWarning ? 145 : paddingH)
        .frame(maxWidth: .infinity, minHeight: fieldHeight)
        .background(Color.tField)
        .cornerRadius(cornerRadius)
        .overlay(fieldBorder)
        .foregroundColor(.primary)
        .font(.system(size: fontSizeCode))
        .tint(.blue)
        .keyboardType(.asciiCapable)
        .textContentType(.oneTimeCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .disabled(isDisabled)
        .onChange(of: text) { _, newValue in
            handleTextChange(newValue)
        }
    }
    
    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Color.gray, lineWidth: lineWidth)
    }
    
    // MARK: - Body
    var body: some View {
        ZStack(alignment: .trailing) {
            textField

            if showLimitWarning {
                Text(Inc.Registration.warningCharactersEight.localized)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .padding(.trailing, paddingH)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear {
            warningTask?.cancel()
        }
    }
}
