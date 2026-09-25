import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var appLock = ShumAppLock.shared

    @State private var hasReachedMinimumSplashDuration = false
    @State private var showsAppSwitcherPrivacyCover = false

    private let minimumSplashDuration: UInt64 = 600_000_000
    private let remainingFallbackDuration: UInt64 = 1_400_000_000

    var body: some View {
        ZStack {
            Group {
                if coordinator.showsDeletionCeremony {
                    ShumDeletionCeremonyView {
                        coordinator.completeDeletionCeremony()
                    }
                } else if coordinator.deletingProfile {
                    VStack(spacing: 20) {
                        Text("Завершение удаления".localized).font(.title2.bold())
                        Text(coordinator.deletionError ?? "Обмен сообщениями остановлен.".localized).multilineTextAlignment(.center)
                        RegistrationPrimaryButton(title: "Повторить удаление".localized) { coordinator.finishDeletion() }
                    }.padding(24)
                } else if coordinator.isRegistered, let chat = coordinator.chat {
                    MainContentView(chat: chat,
                        profilePhotoViewModel: coordinator.profilePhotoViewModel
                    )
                } else {
                    Welcome()
                        .id(coordinator.authenticationFlowID)
                }
            }
            // Profile deletion replaces the complete app session. Giving the
            // session root a new identity also discards any presentation host
            // that may still be finishing a sheet dismissal.
            .id(coordinator.authenticationFlowID)

            if coordinator.showSplash {
                AppSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if coordinator.isRegistered && appLock.isLocked {
                ShumLockedView(appLock: appLock)
                    .transition(.opacity)
                    .zIndex(2)
            }

            if showsAppSwitcherPrivacyCover {
                ShumPrivacyCover()
                    .zIndex(11)
            }
        }
        .onOpenURL { url in
            coordinator.handleInvitationURL(url)
        }
        .alert("Контакт Shum".localized, isPresented: Binding(get: { coordinator.invitationError != nil }, set: { if !$0 { coordinator.invitationError = nil } })) {
            Button("Понятно".localized) { coordinator.invitationError = nil }
        } message: { Text(coordinator.invitationError ?? "") }
        .environmentObject(coordinator)
        .task {
            coordinator.updateApplicationState(
                isActive: scenePhase == .active
            )

            guard coordinator.showSplash else { return }

            try? await Task.sleep(
                nanoseconds: minimumSplashDuration
            )

            guard !Task.isCancelled else { return }
            hasReachedMinimumSplashDuration = true
            hideSplashIfReady()

            guard coordinator.showSplash else { return }

            try? await Task.sleep(
                nanoseconds: remainingFallbackDuration
            )

            guard !Task.isCancelled, coordinator.showSplash else { return }
            hideSplash()
        }
        .shumOnChange(of: coordinator.hasCompletedInitialSessionRefresh) {
            _, isComplete in
            guard isComplete else { return }
            hideSplashIfReady()
        }
        .shumOnChange(of: appLock.isLocked) { _, _ in
            coordinator.updateApplicationState(
                isActive: scenePhase == .active
            )
        }
        .shumOnChange(of: scenePhase) { previousPhase, phase in
            coordinator.updateApplicationState(isActive: phase == .active)

            updateAppSwitcherPrivacyCover(
                from: previousPhase,
                to: phase
            )

            if phase == .active {
                Task {
                    await coordinator.refreshSession()
                }
            }
        }
    }

    private func hideSplashIfReady() {
        guard hasReachedMinimumSplashDuration,
              coordinator.hasCompletedInitialSessionRefresh else {
            return
        }

        hideSplash()
    }

    private func hideSplash() {
        guard coordinator.showSplash else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            coordinator.showSplash = false
        }
    }

    private func updateAppSwitcherPrivacyCover(
        from previousPhase: ScenePhase,
        to phase: ScenePhase
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            switch phase {
            case .background:
                showsAppSwitcherPrivacyCover = true
            case .inactive:
                // Cover the outgoing app before iOS takes its app-switcher
                // snapshot. On the return path, remove the cover while the
                // scene is still inactive so it cannot flash on screen.
                showsAppSwitcherPrivacyCover = previousPhase == .active
            case .active:
                showsAppSwitcherPrivacyCover = false
            @unknown default:
                showsAppSwitcherPrivacyCover = true
            }
        }
    }
}

private struct ShumDeletionCeremonyView: View {
    @Environment(\.shumThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let completion: () -> Void

    @State private var animationStartedAt = Date()
    @State private var completed = false

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Text(completed ? "Данные уничтожены".localized : "Уничтожаем данные".localized)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)

                Group {
                    if completed {
                        ShumDeletionCompleteIllustration()
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    } else {
                        ShumDeletionIllustration(
                            animationStartedAt: animationStartedAt,
                            reduceMotion: reduceMotion
                        )
                        .transition(.opacity)
                    }
                }
                .frame(width: 220, height: 210)
                .padding(.top, 30)

                Text(completed
                    ? "На устройстве не осталось профиля, ключей и переписки.".localized
                    : "Личные данные удалены с устройства.".localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 350)
                    .contentTransition(.opacity)

                Spacer()

                if completed {
                    RegistrationPrimaryButton(
                        title: "Начать заново".localized,
                        isEnabled: true,
                        accentColor: palette.accent,
                        action: completion
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.28), value: completed)
        .task {
            animationStartedAt = Date()
            let soft = UIImpactFeedbackGenerator(style: .soft)
            let success = UINotificationFeedbackGenerator()
            soft.prepare()
            success.prepare()
            soft.impactOccurred(intensity: 0.7)
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard !Task.isCancelled else { return }
            soft.impactOccurred(intensity: 0.9)
            try? await Task.sleep(nanoseconds: 1_150_000_000)
            guard !Task.isCancelled else { return }
            success.notificationOccurred(.success)
            completed = true
        }
    }
}

private struct ShumDeletionIllustration: View {
    @Environment(\.shumThemePalette) private var palette

    let animationStartedAt: Date
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(animationStartedAt)
            let progress = reduceMotion
                ? min(max(elapsed / 1.8, 0), 1)
                : min(max(elapsed / 2.25, 0), 1)
            let eased = progress * progress * (3 - 2 * progress)

            Canvas(rendersAsynchronously: true) { context, size in
                let unit = min(size.width / 31, size.height / 31)
                let origin = CGPoint(
                    x: (size.width - 29 * unit) / 2,
                    y: (size.height - 29 * unit) / 2
                )
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                for (index, pixel) in Self.pixels.enumerated() {
                    let base = CGPoint(
                        x: origin.x + CGFloat(pixel.x) * unit,
                        y: origin.y + CGFloat(pixel.y) * unit
                    )
                    let dx = base.x - center.x
                    let dy = base.y - center.y
                    let distance = max(sqrt(dx * dx + dy * dy), 1)
                    let jitterX = CGFloat(((index * 19) % 17) - 8) * unit
                    let jitterY = CGFloat(((index * 13) % 19) - 9) * unit
                    let travel = CGFloat(eased) * (reduceMotion ? 0.18 : 0.72)
                    let point = CGPoint(
                        x: base.x + dx / distance * unit * 15 * travel + jitterX * travel,
                        y: base.y + dy / distance * unit * 15 * travel + jitterY * travel
                    )
                    let shrink = CGFloat(eased) * unit * 0.36
                    let rect = CGRect(
                        x: point.x + shrink,
                        y: point.y + shrink,
                        width: max(1, unit - 0.7 - shrink * 2),
                        height: max(1, unit - 0.7 - shrink * 2)
                    )
                    let isFadingParticle = index.isMultiple(of: 4) || progress > 0.65
                    let color = isFadingParticle ? Color.secondary : palette.accent
                    context.fill(
                        Path(rect),
                        with: .color(color.opacity(max(0, 1 - eased * 0.94)))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static let pixels: [Pixel] = shield(x: 5, y: 1)
        + key(x: 10, y: 6)

    private static func shield(x: Int, y: Int) -> [Pixel] {
        var result = line(from: Pixel(x + 2, y), to: Pixel(x + 16, y))
        result += [Pixel(x + 1, y + 1), Pixel(x + 17, y + 1)]
        result += line(from: Pixel(x, y + 2), to: Pixel(x, y + 13))
        result += line(from: Pixel(x + 18, y + 2), to: Pixel(x + 18, y + 13))
        for step in 0...8 {
            result += [Pixel(x + step + 1, y + step + 14), Pixel(x + 17 - step, y + step + 14)]
        }
        return result + [Pixel(x + 9, y + 23)]
    }

    private static func key(x: Int, y: Int) -> [Pixel] {
        outline(x: x + 2, y: y, width: 8, height: 8)
        + line(from: Pixel(x + 6, y + 8), to: Pixel(x + 6, y + 19))
        + line(from: Pixel(x + 6, y + 15), to: Pixel(x + 10, y + 15))
        + line(from: Pixel(x + 6, y + 18), to: Pixel(x + 9, y + 18))
        + [Pixel(x + 5, y + 3), Pixel(x + 6, y + 3)]
    }

    private static func outline(x: Int, y: Int, width: Int, height: Int) -> [Pixel] {
        line(from: Pixel(x + 1, y), to: Pixel(x + width - 2, y))
        + line(from: Pixel(x + 1, y + height - 1), to: Pixel(x + width - 2, y + height - 1))
        + line(from: Pixel(x, y + 1), to: Pixel(x, y + height - 2))
        + line(from: Pixel(x + width - 1, y + 1), to: Pixel(x + width - 1, y + height - 2))
    }

    private static func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        guard steps > 0 else { return [start] }
        return (0...steps).map { step in
            Pixel(
                start.x + (end.x - start.x) * step / steps,
                start.y + (end.y - start.y) * step / steps
            )
        }
    }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}

private struct ShumDeletionCompleteIllustration: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 27, size.height / 24)
            let origin = CGPoint(
                x: (size.width - 23 * unit) / 2,
                y: (size.height - 18 * unit) / 2
            )
            for pixel in Self.cloudPixels {
                fill(pixel, color: palette.accent.opacity(0.28), context: &context, origin: origin, unit: unit)
            }
            for pixel in Self.checkPixels {
                fill(pixel, color: palette.accent, context: &context, origin: origin, unit: unit)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(
        _ pixel: Pixel,
        color: Color,
        context: inout GraphicsContext,
        origin: CGPoint,
        unit: CGFloat
    ) {
        let rect = CGRect(
            x: origin.x + CGFloat(pixel.x) * unit,
            y: origin.y + CGFloat(pixel.y) * unit,
            width: max(1, unit - 0.8),
            height: max(1, unit - 0.8)
        )
        context.fill(Path(rect), with: .color(color))
    }

    private static let cloudPixels: [Pixel] = [
        Pixel(3, 7), Pixel(5, 4), Pixel(8, 2), Pixel(12, 3),
        Pixel(16, 2), Pixel(19, 5), Pixel(21, 8), Pixel(20, 12),
        Pixel(17, 15), Pixel(13, 17), Pixel(9, 16), Pixel(5, 14),
        Pixel(2, 11), Pixel(7, 7), Pixel(15, 7), Pixel(18, 10),
        Pixel(6, 12), Pixel(11, 14)
    ]
    private static let checkPixels: [Pixel] =
        line(from: Pixel(7, 9), to: Pixel(11, 13))
        + line(from: Pixel(11, 13), to: Pixel(17, 7))

    private static func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        guard steps > 0 else { return [start] }
        return (0...steps).map { step in
            Pixel(
                start.x + (end.x - start.x) * step / steps,
                start.y + (end.y - start.y) * step / steps
            )
        }
    }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}

private struct ShumLockedView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var appLock: ShumAppLock
    @State private var showingPasscode: Bool
    @State private var isWaitingForAutomaticBiometrics: Bool
    @State private var code = ""
    @State private var isCheckingCode = false

    init(appLock: ShumAppLock) {
        self.appLock = appLock
        let usesAutomaticBiometrics = appLock.preferredMethod == .biometrics
            && appLock.isBiometricsEnabled
        _showingPasscode = State(
            initialValue: appLock.preferredMethod == .passcode
        )
        _isWaitingForAutomaticBiometrics = State(
            initialValue: usesAutomaticBiometrics
        )
    }

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if isWaitingForAutomaticBiometrics {
                AppSplashView()
            } else if showingPasscode, appLock.hasPasscode {
                passcodeContent
            } else {
                biometricContent
            }
        }
        .task {
            guard appLock.preferredMethod == .biometrics,
                  appLock.isBiometricsEnabled,
                  !showingPasscode else {
                return
            }

            let unlocked = await appLock.unlock()
            guard !unlocked else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isWaitingForAutomaticBiometrics = false
            }
        }
    }

    private var passcodeContent: some View {
        VStack(spacing: 18) {
            ShumLogoMark()
                .frame(width: 70, height: 70)

            Text("Введите код Shum".localized)
                .font(.title2.weight(.semibold))

            Text("Введите пять цифр, чтобы открыть переписку.".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ShumPasscodeInput(code: $code)
                .padding(.vertical, 12)

            if let message = appLock.errorMessage {
                errorText(message)
            }

            if appLock.isBiometricsEnabled {
                Button(String.localizedFormat("Открыть с %@".localized, appLock.biometricTitle)) {
                    code = ""
                    showingPasscode = false
                    Task { _ = await appLock.unlockWithBiometrics() }
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 44)
            }
        }
        .padding(24)
        .onChange(of: code) { value in
            guard value.count == 5, !isCheckingCode else { return }
            isCheckingCode = true
            Task {
                let unlocked = await appLock.verifyPasscode(value)
                isCheckingCode = false
                if !unlocked { code = "" }
            }
        }
    }

    private var biometricContent: some View {
        VStack(spacing: 18) {
            ShumLogoMark()
                .frame(width: 76, height: 76)

            Text("Shum заблокирован".localized)
                .font(.title2.weight(.semibold))

            Text("Подтвердите владельца устройства, чтобы открыть переписку.".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if appLock.isBiometricsEnabled {
                Button {
                    Task { _ = await appLock.unlockWithBiometrics() }
                } label: {
                    Text(String.localizedFormat("Открыть с %@".localized, appLock.biometricTitle))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.accentForeground)
                        .frame(maxWidth: 300)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appLock.isAuthenticating)
            }

            if appLock.hasPasscode {
                Button("Ввести код".localized) {
                    appLock.errorMessage = nil
                    showingPasscode = true
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 44)
            }

            if let message = appLock.errorMessage {
                errorText(message)
            }
        }
        .padding(24)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
    }
}

private struct AppSplashView: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        ZStack {
            palette.privacySurface

            ShumLogoMark(color: palette.accent)
                .frame(width: 82, height: 82)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
