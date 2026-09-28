import SwiftUI
import UIKit

struct RegistrationSecurityCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator

    let name: String
    let avatarSeed: UInt64?

    @State private var stage = 0
    @State private var animationStartedAt = Date()
    @State private var isRunning = false
    @State private var ceremonyCompleted = false
    @State private var showReady = false
    @State private var showError = false

    private let stageTitles = [
        "Криптографические ключи".localized,
        "Шифрование".localized,
        "Защищённое хранилище".localized,
        "Проверка".localized
    ]

    private var activeStageTitle: String {
        switch stage {
        case 0: "Создаём криптографические ключи".localized
        case 1: "Шифруем хранилище".localized
        case 2: "Сохраняем ключи на устройстве".localized
        default: "Проверяем защиту".localized
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 26)

            RegistrationKeyCreationIllustration(
                animationStartedAt: animationStartedAt
            )
            .frame(width: 190, height: 174)
            .accessibilityHidden(true)

            Text("Создаём вашу защиту".localized)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)

            Text("Ключи создаются и сохраняются\nтолько на этом устройстве.".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)

            Spacer(minLength: 30)

            Text(activeStageTitle)
                .font(.system(size: 16, weight: .regular))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: stage)

            HStack(spacing: 8) {
                ForEach(stageTitles.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= min(stage, 3)
                            ? Color.accentColor
                            : Color.secondary.opacity(0.24))
                        .frame(height: 5)
                }
            }
            .frame(maxWidth: 310)
            .padding(.top, 14)

            VStack(spacing: 13) {
                ForEach(stageTitles.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        ZStack {
                            if index < stage || stage > 3 {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Circle()
                                    .fill(stage == index
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.38))
                                    .frame(width: 17, height: 17)
                            }
                        }
                        .frame(width: 17, height: 17)

                        Text(stageTitles[index])
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(index <= stage ? Color.primary : Color.secondary)

                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: 310)
            .padding(.top, 24)
            .animation(.easeInOut(duration: 0.22), value: stage)

            Spacer(minLength: 24)

            if ceremonyCompleted {
                RegistrationPrimaryButton(
                    title: "Продолжить".localized,
                    isEnabled: true,
                    accentColor: Color.accentColor
                ) {
                    showReady = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            } else {
                Text("Не закрывайте Shum".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle("Защита".localized)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $showReady) {
            RegistrationSecurityReadyView()
        }
        .alert("Не удалось создать защиту".localized, isPresented: $showError) {
            Button("Повторить".localized) {
                Task { await runCreationCeremony() }
            }
            Button("Назад".localized, role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Разблокируйте устройство и попробуйте ещё раз.".localized)
        }
        .task {
            await runCreationCeremony()
        }
    }

    @MainActor
    private func runCreationCeremony() async {
        guard !isRunning else { return }
        isRunning = true
        ceremonyCompleted = false
        showError = false
        stage = 0
        animationStartedAt = Date()

        let softFeedback = UIImpactFeedbackGenerator(style: .soft)
        let mediumFeedback = UIImpactFeedbackGenerator(style: .medium)
        let rigidFeedback = UIImpactFeedbackGenerator(style: .rigid)
        let successFeedback = UINotificationFeedbackGenerator()
        softFeedback.prepare()
        mediumFeedback.prepare()
        rigidFeedback.prepare()
        successFeedback.prepare()

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            softFeedback.impactOccurred(intensity: 0.65)

            let saved = coordinator.authCodeViewModel.save(
                name: name,
                photo: nil,
                avatarSeed: avatarSeed
            )
            let prepared = saved && coordinator.prepareRegistrationSecurity()

            try await Task.sleep(nanoseconds: 1_150_000_000)
            guard !Task.isCancelled else { return }
            stage = 1
            softFeedback.impactOccurred(intensity: 0.85)

            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            stage = 2
            mediumFeedback.impactOccurred(intensity: 0.75)

            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            stage = 3
            rigidFeedback.impactOccurred(intensity: 0.65)

            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            guard prepared else {
                isRunning = false
                showError = true
                return
            }

            stage = 4
            successFeedback.notificationOccurred(.success)
            try await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            isRunning = false
            withAnimation(.easeOut(duration: 0.28)) {
                ceremonyCompleted = true
            }
        } catch {
            isRunning = false
        }
    }
}
private struct RegistrationKeyCreationIllustration: View {
    let animationStartedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(animationStartedAt)

            Canvas(rendersAsynchronously: true) { context, size in
                let unit = min(size.width / 36, size.height / 31)
                let origin = CGPoint(
                    x: (size.width - 32 * unit) / 2,
                    y: (size.height - 29 * unit) / 2
                )
                let accent = Color.accentColor
                let keyProgress = eased(progress(elapsed, from: 0.05, duration: 1.35))
                let shieldProgress = eased(progress(elapsed, from: 1.25, duration: 1.8))
                let storageProgress = eased(progress(elapsed, from: 2.75, duration: 1.55))
                let verificationProgress = eased(progress(elapsed, from: 4.35, duration: 1.35))
                let completionProgress = eased(progress(elapsed, from: 5.65, duration: 0.65))

                draw(
                    Self.storagePixels,
                    progress: storageProgress,
                    color: Color.secondary.opacity(0.5 * (1 - completionProgress)),
                    scatter: false,
                    in: &context,
                    origin: origin,
                    unit: unit
                )
                draw(
                    Self.shieldPixels,
                    progress: shieldProgress,
                    color: .primary.opacity(0.94 * (1 - completionProgress)),
                    scatter: false,
                    in: &context,
                    origin: origin,
                    unit: unit
                )
                draw(
                    Self.keyPixels,
                    progress: keyProgress,
                    color: .primary.opacity(1 - completionProgress),
                    scatter: true,
                    in: &context,
                    origin: origin,
                    unit: unit
                )
                draw(
                    Self.cloudPixels,
                    progress: keyProgress,
                    color: accent.opacity(1 - completionProgress),
                    scatter: true,
                    in: &context,
                    origin: origin,
                    unit: unit
                )

                if elapsed > 1.1, elapsed < 4.5 {
                    for (index, pixel) in Self.dataPixels.enumerated() {
                        let pulse = (sin(elapsed * 5 + Double(index) * 1.7) + 1) / 2
                        let rect = pixelRect(pixel, origin: origin, unit: unit)
                        context.fill(
                            Path(rect),
                            with: .color(index.isMultiple(of: 3)
                                ? accent.opacity(0.35 + 0.6 * pulse)
                                : Color.secondary.opacity(0.25 + 0.45 * pulse))
                        )
                    }
                }

                if verificationProgress > 0 {
                    let scanY = origin.y + (4 + 20 * verificationProgress) * unit
                    let scanRect = CGRect(
                        x: origin.x + 6 * unit,
                        y: scanY,
                        width: 20 * unit,
                        height: max(1.5, unit * 0.45)
                    )
                    context.fill(
                        Path(scanRect),
                        with: .color(accent.opacity(0.72 * (1 - completionProgress)))
                    )
                    draw(
                        Self.checkPixels,
                        progress: verificationProgress,
                        color: accent.opacity(1 - completionProgress),
                        scatter: false,
                        in: &context,
                        origin: origin,
                        unit: unit
                    )
                }

                if completionProgress > 0 {
                    context.drawLayer { glowingContext in
                        glowingContext.addFilter(
                            .shadow(
                                color: accent.opacity(0.35 + completionProgress * 0.45),
                                radius: 2 + completionProgress * 6
                            )
                        )
                        draw(
                            Self.shieldPixels,
                            progress: shieldProgress,
                            color: accent.opacity(completionProgress),
                            scatter: false,
                            in: &glowingContext,
                            origin: origin,
                            unit: unit
                        )
                        draw(
                            Self.keyPixels,
                            progress: keyProgress,
                            color: accent.opacity(completionProgress),
                            scatter: false,
                            in: &glowingContext,
                            origin: origin,
                            unit: unit
                        )
                        draw(
                            Self.cloudPixels,
                            progress: keyProgress,
                            color: accent.opacity(completionProgress),
                            scatter: false,
                            in: &glowingContext,
                            origin: origin,
                            unit: unit
                        )
                        draw(
                            Self.checkPixels,
                            progress: verificationProgress,
                            color: accent.opacity(completionProgress),
                            scatter: false,
                            in: &glowingContext,
                            origin: origin,
                            unit: unit
                        )
                    }
                }
            }
        }
    }

    private func progress(_ elapsed: TimeInterval, from start: TimeInterval, duration: TimeInterval) -> Double {
        min(max((elapsed - start) / duration, 0), 1)
    }

    private func eased(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private func draw(
        _ pixels: [CeremonyPixel],
        progress: Double,
        color: Color,
        scatter: Bool,
        in context: inout GraphicsContext,
        origin: CGPoint,
        unit: CGFloat
    ) {
        guard progress > 0 else { return }
        let revealed = progress * Double(pixels.count + 6)

        for (index, pixel) in pixels.enumerated() {
            let localProgress = min(max(revealed - Double(index), 0), 1)
            guard localProgress > 0 else { continue }

            let horizontalOffset = scatter
                ? CGFloat(((index * 17) % 13) - 6) * unit * (1 - localProgress)
                : 0
            let verticalOffset = scatter
                ? CGFloat(((index * 11) % 15) - 7) * unit * (1 - localProgress)
                : 0
            var rect = pixelRect(pixel, origin: origin, unit: unit)
            rect.origin.x += horizontalOffset
            rect.origin.y += verticalOffset
            let inset = unit * CGFloat(1 - localProgress) * 0.35
            rect = rect.insetBy(dx: inset, dy: inset)
            context.fill(Path(rect), with: .color(color.opacity(localProgress)))
        }
    }

    private func pixelRect(_ pixel: CeremonyPixel, origin: CGPoint, unit: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(pixel.x) * unit,
            y: origin.y + CGFloat(pixel.y) * unit,
            width: max(unit - 0.7, 1),
            height: max(unit - 0.7, 1)
        )
    }

    private static let keyPixels: [CeremonyPixel] = {
        outline(x: 12, y: 5, width: 9, height: 9)
        + vertical(x: 16, from: 14, through: 24)
        + horizontal(y: 20, from: 16, through: 20)
        + horizontal(y: 23, from: 16, through: 19)
    }()

    private static let cloudPixels: [CeremonyPixel] = [
        CeremonyPixel(14, 10), CeremonyPixel(15, 9), CeremonyPixel(16, 9),
        CeremonyPixel(17, 10), CeremonyPixel(18, 10), CeremonyPixel(14, 11),
        CeremonyPixel(15, 11), CeremonyPixel(16, 11), CeremonyPixel(17, 11),
        CeremonyPixel(18, 11)
    ]

    private static let shieldPixels: [CeremonyPixel] = {
        horizontal(y: 2, from: 8, through: 24)
        + [CeremonyPixel(7, 3), CeremonyPixel(25, 3)]
        + vertical(x: 6, from: 4, through: 16)
        + vertical(x: 26, from: 4, through: 16)
        + [CeremonyPixel(7, 17), CeremonyPixel(25, 17),
           CeremonyPixel(8, 18), CeremonyPixel(24, 18),
           CeremonyPixel(9, 19), CeremonyPixel(23, 19),
           CeremonyPixel(10, 20), CeremonyPixel(22, 20),
           CeremonyPixel(11, 21), CeremonyPixel(21, 21),
           CeremonyPixel(12, 22), CeremonyPixel(20, 22),
           CeremonyPixel(13, 23), CeremonyPixel(19, 23),
           CeremonyPixel(14, 24), CeremonyPixel(18, 24),
           CeremonyPixel(15, 25), CeremonyPixel(17, 25), CeremonyPixel(16, 26)]
    }()

    private static let storagePixels: [CeremonyPixel] = {
        let frame = outline(x: 3, y: 0, width: 27, height: 29)
        let topPins = stride(from: 7, through: 25, by: 4).flatMap {
            [CeremonyPixel($0, 0), CeremonyPixel($0, -1)]
        }
        let bottomPins = stride(from: 7, through: 25, by: 4).flatMap {
            [CeremonyPixel($0, 28), CeremonyPixel($0, 29)]
        }
        return frame + topPins + bottomPins
    }()

    private static let checkPixels: [CeremonyPixel] =
        diagonal(from: CeremonyPixel(11, 15), to: CeremonyPixel(15, 19))
        + diagonal(from: CeremonyPixel(15, 19), to: CeremonyPixel(22, 12))

    private static let dataPixels: [CeremonyPixel] = [
        CeremonyPixel(3, 8), CeremonyPixel(2, 14), CeremonyPixel(4, 22),
        CeremonyPixel(29, 7), CeremonyPixel(30, 13), CeremonyPixel(28, 21),
        CeremonyPixel(8, 1), CeremonyPixel(23, 0), CeremonyPixel(10, 27),
        CeremonyPixel(24, 27)
    ]

    private static func outline(x: Int, y: Int, width: Int, height: Int) -> [CeremonyPixel] {
        horizontal(y: y, from: x + 1, through: x + width - 2)
        + vertical(x: x, from: y + 1, through: y + height - 2)
        + vertical(x: x + width - 1, from: y + 1, through: y + height - 2)
        + horizontal(y: y + height - 1, from: x + 1, through: x + width - 2)
    }

    private static func horizontal(y: Int, from start: Int, through end: Int) -> [CeremonyPixel] {
        guard start <= end else { return [] }
        return (start...end).map { CeremonyPixel($0, y) }
    }

    private static func vertical(x: Int, from start: Int, through end: Int) -> [CeremonyPixel] {
        guard start <= end else { return [] }
        return (start...end).map { CeremonyPixel(x, $0) }
    }

    private static func diagonal(from start: CeremonyPixel, to end: CeremonyPixel) -> [CeremonyPixel] {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        guard steps > 0 else { return [start] }
        return (0...steps).map { step in
            CeremonyPixel(
                start.x + (end.x - start.x) * step / steps,
                start.y + (end.y - start.y) * step / steps
            )
        }
    }

    private struct CeremonyPixel: Hashable {
        let x: Int
        let y: Int

        init(_ x: Int, _ y: Int) {
            self.x = x
            self.y = y
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text("Защита готова".localized)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Уникальные ключи защищают ваш профиль и сообщения. Закрытые ключи не передаются Shum и не покидают устройство.".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 350)

            VStack(spacing: 14) {
                securityStatus("Ключ профиля создан".localized)
                securityStatus("Сквозное шифрование включено".localized)
                securityStatus("Ключи сохранены на устройстве".localized)
            }
            .padding(.top, 30)

            if let fingerprint = coordinator.identityFingerprint {
                Text(String.localizedFormat("Отпечаток %@".localized, fingerprint))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            }

            Spacer()

            RegistrationPrimaryButton(
                title: "Продолжить".localized,
                isEnabled: true,
                accentColor: Color.accentColor
            ) {
                showPasscode = true
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPasscode) {
            RegistrationPasscodeSetupView()
        }
    }

    private func securityStatus(_ title: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 310)
    }
}
struct RegistrationPasscodeSetupView: View {
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text(phase == .create ? "Создайте код Shum".localized : "Повторите код".localized)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Пять цифр защитят переписку, если Face ID недоступен.".localized)
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
                title: phase == .create ? "Продолжить".localized : "Сохранить код".localized,
                isEnabled: code.count == 5 && !isSaving,
                accentColor: Color.accentColor,
                action: continueFlow
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(ShumThemeCanvas().ignoresSafeArea())
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
            message = "Коды не совпадают. Попробуйте ещё раз.".localized
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text(String.localizedFormat("Открывать Shum с %@".localized, appLock.biometricTitle))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text("Защитите доступ к переписке, если устройство окажется у другого человека.".localized)
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
                    title: String.localizedFormat("Включить %@".localized, appLock.biometricTitle),
                    isEnabled: !isWorking,
                    accentColor: Color.accentColor
                ) {
                    enableProtection()
                }

                Button("Использовать код".localized) {
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
        .background(ShumThemeCanvas().ignoresSafeArea())
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
