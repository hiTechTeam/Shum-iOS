import SwiftUI

struct ShumPasscodeInput: View {
    @Binding var code: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < code.count ? Color.primary : Color.clear)
                        .overlay {
                            Circle()
                                .stroke(Color.secondary, lineWidth: 1.5)
                        }
                        .frame(width: 14, height: 14)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityLabel("Код Shum")
                .accessibilityIdentifier("shum.passcode")
        }
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: code) { value in
            let filtered = value.filter { character in
                character.unicodeScalars.allSatisfy { (48...57).contains(Int($0.value)) }
            }
            let limited = String(filtered.prefix(5))
            if limited != value { code = limited }
        }
    }
}
