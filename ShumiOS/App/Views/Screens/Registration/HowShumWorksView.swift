import SwiftUI
import UIKit

struct HowShumWorksView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var page = 0
    @State private var showRegistration = false

    private let pages: [ShumOnboardingContent] = [
        ShumOnboardingContent(
            illustration: .nearby,
            title: "Люди рядом",
            description: "Shum находит людей поблизости по Bluetooth. Можно познакомиться и начать общение напрямую между устройствами."
        ),
        ShumOnboardingContent(
            illustration: .mesh,
            title: "Связь без интернета",
            description: "Если рядом есть другие пользователи Shum, сообщения проходят по mesh-сети от устройства к устройству. Интернет не нужен."
        ),
        ShumOnboardingContent(
            illustration: .courier,
            title: "Сообщение найдёт путь",
            description: "Устройство рядом может временно сохранить зашифрованное сообщение и передать его дальше позже. Содержимое видите только вы и получатель."
        ),
        ShumOnboardingContent(
            illustration: .network,
            title: "Общайтесь без единого центра",
            description: "У Shum нет единого сервера, который управляет общением. Сообщения передаются напрямую и через распределённую сеть Nostr."
        ),
        ShumOnboardingContent(
            illustration: .identity,
            title: "Ваш профиль принадлежит вам",
            description: "Профиль защищён криптографическими ключами на устройстве. Только вы управляете своей личностью и резервной копией."
        )
    ]

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, content in
                ShumOnboardingPage(
                    illustration: content.illustration,
                    title: content.title,
                    description: content.description,
                    pageIndex: index,
                    pageCount: pages.count,
                    buttonTitle: index == pages.indices.last ? "Создать профиль" : "Продолжить"
                ) {
                    continueOnboarding(from: index)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(ShumThemeCanvas().ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.25), value: page)
        .navigationDestination(isPresented: $showRegistration) {
            LocalCardRegistration(photoViewModel: coordinator.profilePhotoViewModel)
        }
    }

    private func continueOnboarding(from index: Int) {
        guard index == page else { return }
        if page < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
        } else {
            showRegistration = true
        }
    }
}

private struct ShumOnboardingContent {
    let illustration: ShumOnboardingPixelIllustration.Kind
    let title: String
    let description: String
}

struct RegistrationSecurityCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator

    let name: String
    let photo: Data?
    var photoEditing: LocalPhotoEditingState? = nil

    @State private var stage = 0
    @State private var animationStartedAt = Date()
    @State private var isRunning = false
    @State private var ceremonyCompleted = false
    @State private var showReady = false
    @State private var showError = false

    private let stageTitles = [
        "Криптографические ключи",
        "Шифрование",
        "Защищённое хранилище",
        "Проверка"
    ]

    private var activeStageTitle: String {
        switch stage {
        case 0: "Создаём криптографические ключи"
        case 1: "Шифруем хранилище"
        case 2: "Сохраняем ключи на устройстве"
        default: "Проверяем защиту"
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

            Text("Создаём вашу защиту")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)

            Text("Ключи создаются и сохраняются\nтолько на этом устройстве.")
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
                    title: "Продолжить",
                    isEnabled: true,
                    accentColor: Color.accentColor
                ) {
                    showReady = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            } else {
                Text("Не закрывайте Shum")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle("Защита")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $showReady) {
            RegistrationSecurityReadyView()
        }
        .alert("Не удалось создать защиту", isPresented: $showError) {
            Button("Повторить") {
                Task { await runCreationCeremony() }
            }
            Button("Назад", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Разблокируйте устройство и попробуйте ещё раз.")
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
                photo: photo,
                photoEditing: photoEditing
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
                .foregroundStyle(Color.accentColor)
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
                    accentColor: Color.accentColor
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

private struct ShumOnboardingPage: View {
    let illustration: ShumOnboardingPixelIllustration.Kind
    let title: String
    let description: String
    let pageIndex: Int
    let pageCount: Int
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: illustration)
                .foregroundStyle(Color.accentColor)
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

            HStack(spacing: 9) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.38))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Экран \(pageIndex + 1) из \(pageCount)")
            .padding(.bottom, 30)

            RegistrationPrimaryButton(
                title: buttonTitle,
                isEnabled: true,
                accentColor: Color.accentColor,
                action: action
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ShumOnboardingPixelIllustration: View {
    enum Kind { case nearby, mesh, courier, network, identity, security, passcode, faceID, success, failure }

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
        case .nearby:
            return Set(
                person(x: 0, y: 6)
                + person(x: 16, y: 6)
                + bluetooth(x: 11, y: 5)
                + [Pixel(8, 9), Pixel(9, 8), Pixel(9, 10), Pixel(15, 8), Pixel(15, 10), Pixel(16, 9)]
            )
        case .mesh:
            return Set(
                device(x: 1, y: 1)
                + device(x: 10, y: 0)
                + device(x: 19, y: 2)
                + device(x: 4, y: 13)
                + device(x: 16, y: 13)
                + dottedLine(from: Pixel(5, 5), to: Pixel(10, 4))
                + dottedLine(from: Pixel(14, 4), to: Pixel(19, 6))
                + dottedLine(from: Pixel(4, 8), to: Pixel(7, 13))
                + dottedLine(from: Pixel(20, 9), to: Pixel(18, 13))
                + dottedLine(from: Pixel(8, 16), to: Pixel(16, 16))
                + bubble(x: 9, y: 7, tail: .left)
            )
        case .courier:
            return Set(
                device(x: 0, y: 7)
                + device(x: 10, y: 7)
                + device(x: 20, y: 7)
                + dottedLine(from: Pixel(4, 10), to: Pixel(10, 10))
                + dottedLine(from: Pixel(14, 10), to: Pixel(20, 10))
                + [Pixel(8, 9), Pixel(8, 10), Pixel(8, 11), Pixel(18, 9), Pixel(18, 10), Pixel(18, 11)]
                + envelope(x: 8, y: 0)
                + [Pixel(11, 5), Pixel(12, 4), Pixel(13, 5)]
            )
        case .network:
            return Set(
                device(x: 1, y: 1)
                + device(x: 19, y: 1)
                + device(x: 1, y: 13)
                + device(x: 19, y: 13)
                + dottedLine(from: Pixel(5, 4), to: Pixel(19, 4))
                + dottedLine(from: Pixel(4, 8), to: Pixel(4, 13))
                + dottedLine(from: Pixel(20, 8), to: Pixel(20, 13))
                + dottedLine(from: Pixel(5, 16), to: Pixel(19, 16))
                + dottedLine(from: Pixel(5, 7), to: Pixel(19, 13))
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
        case .success:
            return Set(
                resultRing
                + line(from: Pixel(7, 9), to: Pixel(10, 12))
                + line(from: Pixel(10, 12), to: Pixel(16, 6))
            )
        case .failure:
            return Set(
                resultRing
                + line(from: Pixel(11, 5), to: Pixel(11, 10))
                + line(from: Pixel(12, 5), to: Pixel(12, 10))
                + [Pixel(11, 13), Pixel(12, 13)]
            )
        }
    }

    private var resultRing: [Pixel] {
        let upperHalf = line(from: Pixel(8, 1), to: Pixel(15, 1))
            + [Pixel(6, 2), Pixel(7, 2), Pixel(16, 2), Pixel(17, 2)]
            + [Pixel(5, 3), Pixel(18, 3), Pixel(4, 4), Pixel(19, 4)]
            + line(from: Pixel(3, 5), to: Pixel(3, 8))
            + line(from: Pixel(20, 5), to: Pixel(20, 8))
        return upperHalf + upperHalf.map { Pixel($0.x, 17 - $0.y) }
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

    private func device(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 4, height: 8)
            + [Pixel(x + 1, y + 6), Pixel(x + 2, y + 6)]
    }

    private func bluetooth(x: Int, y: Int) -> [Pixel] {
        [
            Pixel(x, y), Pixel(x + 1, y + 1), Pixel(x + 2, y + 2),
            Pixel(x + 1, y + 3), Pixel(x, y + 4), Pixel(x + 1, y + 5),
            Pixel(x + 2, y + 6), Pixel(x + 1, y + 7), Pixel(x, y + 8),
            Pixel(x, y + 2), Pixel(x, y + 6)
        ]
    }

    private func envelope(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 8, height: 6)
            + line(from: Pixel(x + 1, y + 1), to: Pixel(x + 4, y + 3))
            + line(from: Pixel(x + 6, y + 1), to: Pixel(x + 4, y + 3))
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

    private func dottedLine(from start: Pixel, to end: Pixel) -> [Pixel] {
        line(from: start, to: end).enumerated().compactMap { index, pixel in
            index.isMultiple(of: 2) ? pixel : nil
        }
    }

    private enum Tail { case left, right }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}
