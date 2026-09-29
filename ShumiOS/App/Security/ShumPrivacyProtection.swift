import SwiftUI

/// A neutral surface shown in the app switcher snapshot instead of chats.
/// It intentionally contains no profile, notification, or connection state.
struct ShumPrivacyCover: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        ZStack {
            palette.privacySurface

            ShumLogoMark(color: palette.accent)
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Содержимое Shum скрыто".localized)
    }
}
