import SwiftUI

struct BotButton: View {
    
    @Environment(\.openURL) private var openURL
    
    private let title: String = Inc.Profile.telescanBot
    private let fontSize: CGFloat = 14
    private let buttonWidth: CGFloat = 108
    private let buttonHeight: CGFloat = 36
    private let cornerRadius: CGFloat = 13
    
    private func onTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        guard let url = URL(string: Links.telescanBot) else {
            return
        }

        openURL(url)
    }
    
    private var buttonText: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(.blue)
            .fixedSize()
            .frame(width: buttonWidth, height: buttonHeight)
            .cornerRadius(cornerRadius)
    }
    
    private var content: some View {
        Button(action: onTap) {
            buttonText
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
