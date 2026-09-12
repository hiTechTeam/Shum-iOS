import SwiftUI

struct TitleField: View {
    
    // MARK: - Inputs
    var text: String
    
    private let fontSize: CGFloat = 12
    private let frameHeight: CGFloat = 32
    
    private var content: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .frame(
                maxWidth: .infinity,
                minHeight: frameHeight,
                alignment: .leading
            )
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
