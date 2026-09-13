import SwiftUI

struct HowShumWorksView: View {
    @State private var showOwnership = false

    var body: some View {
        ShumOnboardingPage(
            illustration: .network,
            title: "Общайтесь без единого центра",
            description: "Shum передаёт зашифрованные сообщения через открытую сеть Nostr. У мессенджера нет центрального сервера, который хранит ваши разговоры.",
            buttonTitle: "Дальше"
        ) {
            showOwnership = true
        }
        .navigationDestination(isPresented: $showOwnership) {
            ShumProfileOwnershipOnboardingView()
        }
    }
}

private struct ShumProfileOwnershipOnboardingView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showRegistration = false

    var body: some View {
        ShumOnboardingPage(
            illustration: .identity,
            title: "Ваш профиль принадлежит вам",
            description: "Профиль и ключи создаются на этом устройстве. Для регистрации не нужны номер телефона, почта или внешний аккаунт.",
            buttonTitle: "Создать профиль"
        ) {
            showRegistration = true
        }
        .navigationDestination(isPresented: $showRegistration) {
            LocalCardRegistration(photoViewModel: coordinator.profilePhotoViewModel)
        }
    }
}

private struct ShumOnboardingPage: View {
    let illustration: ShumOnboardingPixelIllustration.Kind
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: illustration)
                .foregroundStyle(Color(uiColor: .systemGreen))
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 340)

            Spacer()

            RegistrationPrimaryButton(
                title: buttonTitle,
                isEnabled: true,
                accentColor: Color(uiColor: .systemGreen),
                action: action
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShumOnboardingPixelIllustration: View {
    enum Kind { case network, identity }

    let kind: Kind
    private let unit: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let drawingSize = CGSize(width: 24 * unit, height: 20 * unit)
            let origin = CGPoint(
                x: (proxy.size.width - drawingSize.width) / 2,
                y: (proxy.size.height - drawingSize.height) / 2
            )

            Canvas(rendersAsynchronously: false) { context, _ in
                for pixel in pixels {
                    context.fill(
                        Path(CGRect(
                            x: origin.x + CGFloat(pixel.x) * unit,
                            y: origin.y + CGFloat(pixel.y) * unit,
                            width: unit,
                            height: unit
                        )),
                        with: .foreground
                    )
                }
            }
        }
    }

    private var pixels: Set<Pixel> {
        switch kind {
        case .network:
            return Set(
                bubble(x: 0, y: 1, tail: .left)
                + bubble(x: 16, y: 1, tail: .right)
                + bubble(x: 8, y: 13, tail: .left)
                + line(from: Pixel(8, 4), to: Pixel(15, 4))
                + line(from: Pixel(5, 8), to: Pixel(10, 13))
                + line(from: Pixel(18, 8), to: Pixel(13, 13))
            )
        case .identity:
            return Set(
                outline(x: 5, y: 0, width: 14, height: 20)
                + person(x: 8, y: 4)
                + key(x: 10, y: 14)
            )
        }
    }

    private func bubble(x: Int, y: Int, tail: Tail) -> [Pixel] {
        outline(x: x, y: y, width: 8, height: 7)
        + (tail == .left
            ? [Pixel(x + 2, y + 7), Pixel(x + 2, y + 8), Pixel(x + 3, y + 7)]
            : [Pixel(x + 5, y + 7), Pixel(x + 5, y + 8), Pixel(x + 4, y + 7)])
    }

    private func person(x: Int, y: Int) -> [Pixel] {
        outline(x: x + 2, y: y, width: 4, height: 4)
        + line(from: Pixel(x + 1, y + 5), to: Pixel(x + 6, y + 5))
        + line(from: Pixel(x, y + 6), to: Pixel(x + 7, y + 6))
        + [Pixel(x, y + 7), Pixel(x + 7, y + 7)]
    }

    private func key(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 4, height: 4)
        + line(from: Pixel(x + 4, y + 2), to: Pixel(x + 8, y + 2))
        + [Pixel(x + 6, y + 3), Pixel(x + 8, y + 3)]
    }

    private func outline(x: Int, y: Int, width: Int, height: Int) -> [Pixel] {
        line(from: Pixel(x + 1, y), to: Pixel(x + width - 2, y))
        + line(from: Pixel(x, y + 1), to: Pixel(x, y + height - 2))
        + line(from: Pixel(x + width - 1, y + 1), to: Pixel(x + width - 1, y + height - 2))
        + line(from: Pixel(x + 1, y + height - 1), to: Pixel(x + width - 2, y + height - 1))
    }

    private func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        guard steps > 0 else { return [start] }
        return (0...steps).map { step in
            Pixel(
                start.x + (end.x - start.x) * step / steps,
                start.y + (end.y - start.y) * step / steps
            )
        }
    }

    private enum Tail { case left, right }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}
