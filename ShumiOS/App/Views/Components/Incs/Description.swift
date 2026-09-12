import SwiftUI

struct Description: View {
    
    // MARK: - Inputs
    var text: String
    
    private let topPadding: CGFloat = 32
    
    private var content: some View {
        Text(text)
            .shumDescriptionStyle()
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .padding(.top, topPadding)
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}

private struct ShumDescriptionTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShumSheetTitleTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
    }
}

extension View {
    func shumDescriptionStyle() -> some View {
        modifier(ShumDescriptionTextStyle())
    }

    func shumSheetTitleStyle() -> some View {
        modifier(ShumSheetTitleTextStyle())
    }
}
