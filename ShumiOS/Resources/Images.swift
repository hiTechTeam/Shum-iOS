import SwiftUI

extension Image {
    static let shumLogo = Image("ShumLogo")
    static let chatIcon = Image("ShumLogo")
    static let chatIconDark = Image("ShumLogo")
    static let gradientCircleLight = Image("gradient-circle-light")
    static let gradientCircleDark = Image("gradient-circle-dark")
    static let upChevron = Image("up-chevron")
    static let photoProfile = Image("photo-profile")
    static let infoImage: Image = Image(systemName: "info.circle.fill")
    static let iconEye: Image = Image("icon-eye")
    static let plusChat: Image = Image(systemName: "plus.bubble")
    static let tempChat: Image = Image(systemName: "bubble")
    static let met: Image = Image(systemName: "clock.fill")
    static let tsIconGraySmall: Image = Image("tsIconGraySmall")
    static let noPhoto: Image = Image(systemName: "person.crop.square.on.square.angled.fill")
    static let wave3Up: Image = Image(systemName: "wave.3.up")
    static let personCropCircleFill: Image = Image(systemName: "person.crop.circle.fill")
    static let chevronDownCircleFill: Image = Image(systemName: "chevron.down.circle.fill")
    static let ellipsisCircleFill: Image = Image(systemName: "ellipsis.circle.fill")
    
}

/// Theme-aware pixel cloud used everywhere the Shum mark is shown in-app.
/// The AppIcon remains a fixed system asset; this view follows the active
/// palette by default; callers can supply a fixed color for branded surfaces.
struct ShumLogoMark: View {
    var color: Color = .accentColor

    var body: some View {
        Image.shumLogo
            .renderingMode(.template)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .foregroundStyle(color)
    }
}
