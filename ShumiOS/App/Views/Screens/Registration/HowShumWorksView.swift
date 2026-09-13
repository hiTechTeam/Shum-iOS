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

struct RegistrationSecurityReadyView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showPasscode = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: .security)
                .foregroundStyle(Color(uiColor: .systemGreen))
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text("Защита готова")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Уникальные ключи защищают ваш профиль и сообщения. Закрытые ключи не передаются Shum и не покидают устройство.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 350)

            VStack(spacing: 14) {
                securityStatus("Ключ профиля создан")
                securityStatus("Сквозное шифрование включено")
                securityStatus("Ключи сохранены на устройстве")
            }
            .padding(.top, 30)

            if let fingerprint = coordinator.identityFingerprint {
                Text("Отпечаток \(fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            }

            Spacer()

            RegistrationPrimaryButton(
                title: "Продолжить",
                isEnabled: true,
                accentColor: Color(uiColor: .systemGreen)
            ) {
                showPasscode = true
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPasscode) {
            RegistrationPasscodeSetupView()
        }
    }

    private func securityStatus(_ title: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(uiColor: .systemGreen))
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 310)
    }
}

private struct RegistrationPasscodeSetupView: View {
    private enum Phase {
        case create
        case confirm
    }

    @ObservedObject private var appLock = ShumAppLock.shared
    @State private var phase: Phase = .create
    @State private var firstCode = ""
    @State private var code = ""
    @State private var message: String?
    @State private var isSaving = false
    @State private var showFaceID = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: .passcode)
                .foregroundStyle(Color(uiColor: .systemGreen))
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text(phase == .create ? "Создайте код Shum" : "Повторите код")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Пять цифр защитят переписку, если Face ID недоступен.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 340)

            ShumPasscodeInput(code: $code)
                .padding(.top, 30)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }

            Spacer()

            RegistrationPrimaryButton(
                title: phase == .create ? "Продолжить" : "Сохранить код",
                isEnabled: code.count == 5 && !isSaving,
                accentColor: Color(uiColor: .systemGreen),
                action: continueFlow
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showFaceID) {
            RegistrationFaceIDView()
        }
    }

    private func continueFlow() {
        guard code.count == 5, !isSaving else { return }
        message = nil

        if phase == .create {
            firstCode = code
            code = ""
            phase = .confirm
            return
        }

        guard code == firstCode else {
            code = ""
            message = "Коды не совпадают. Попробуйте ещё раз."
            return
        }

        isSaving = true
        Task {
            let saved = await appLock.setPasscode(code)
            isSaving = false
            if saved {
                showFaceID = true
            } else {
                message = appLock.errorMessage
            }
        }
    }
}

private struct RegistrationFaceIDView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject private var appLock = ShumAppLock.shared
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: .faceID)
                .foregroundStyle(Color(uiColor: .systemGreen))
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text("Открывать Shum с \(appLock.biometricTitle)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Защитите доступ к переписке, если устройство окажется у другого человека.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 340)

            if let message = appLock.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            }

            Spacer()

            VStack(spacing: 10) {
                RegistrationPrimaryButton(
                    title: "Включить \(appLock.biometricTitle)",
                    isEnabled: !isWorking,
                    accentColor: Color(uiColor: .systemGreen)
                ) {
                    enableProtection()
                }

                Button("Использовать код") {
                    appLock.usePasscodeByDefault()
                    coordinator.completedRegistration()
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 44)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enableProtection() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let enabled = await appLock.enable()
            isWorking = false
            if enabled {
                coordinator.completedRegistration()
            }
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
    enum Kind { case network, identity, security, passcode, faceID }

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
        case .security:
            return Set(
                shield(x: 5, y: 0)
                + key(x: 9, y: 8)
            )
        case .passcode:
            return Set(
                outline(x: 5, y: 5, width: 14, height: 12)
                + line(from: Pixel(8, 5), to: Pixel(8, 3))
                + line(from: Pixel(16, 5), to: Pixel(16, 3))
                + line(from: Pixel(9, 2), to: Pixel(15, 2))
                + [Pixel(9, 10), Pixel(12, 10), Pixel(15, 10)]
            )
        case .faceID:
            return Set(
                faceFrame(x: 4, y: 1)
                + [Pixel(9, 7), Pixel(15, 7)]
                + line(from: Pixel(12, 8), to: Pixel(12, 12))
                + line(from: Pixel(9, 15), to: Pixel(15, 15))
            )
        }
    }

    private func shield(x: Int, y: Int) -> [Pixel] {
        var result = line(from: Pixel(x + 2, y), to: Pixel(x + 12, y))
        result += [Pixel(x + 1, y + 1), Pixel(x + 13, y + 1)]
        result += line(from: Pixel(x, y + 2), to: Pixel(x, y + 9))
        result += line(from: Pixel(x + 14, y + 2), to: Pixel(x + 14, y + 9))
        result += [Pixel(x + 1, y + 10), Pixel(x + 13, y + 10)]
        result += [Pixel(x + 2, y + 11), Pixel(x + 12, y + 11)]
        result += [Pixel(x + 3, y + 12), Pixel(x + 11, y + 12)]
        result += [Pixel(x + 4, y + 13), Pixel(x + 10, y + 13)]
        result += [Pixel(x + 5, y + 14), Pixel(x + 9, y + 14)]
        result += [Pixel(x + 6, y + 15), Pixel(x + 8, y + 15), Pixel(x + 7, y + 16)]
        return result
    }

    private func faceFrame(x: Int, y: Int) -> [Pixel] {
        var result = line(from: Pixel(x, y), to: Pixel(x + 5, y))
        result += line(from: Pixel(x, y), to: Pixel(x, y + 5))
        result += line(from: Pixel(x + 11, y), to: Pixel(x + 16, y))
        result += line(from: Pixel(x + 16, y), to: Pixel(x + 16, y + 5))
        result += line(from: Pixel(x, y + 14), to: Pixel(x, y + 19))
        result += line(from: Pixel(x, y + 19), to: Pixel(x + 5, y + 19))
        result += line(from: Pixel(x + 16, y + 14), to: Pixel(x + 16, y + 19))
        result += line(from: Pixel(x + 11, y + 19), to: Pixel(x + 16, y + 19))
        return result
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
