#if os(iOS)
import SwiftUI

struct ShumTypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.34, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Text("Печатает")
            ForEach(0..<3, id: \.self) { index in
                Text(".")
                    .opacity(index <= phase ? 1 : 0.22)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Печатает")
    }
}

struct ShumInvitationRecoverySlider: View {
    let accept: () -> Bool
    @State private var offset: CGFloat = 0
    @State private var crossedFeedbackPoint = false
    @State private var completing = false

    private let controlSize: CGFloat = 38
    private let inset: CGFloat = 4
    private let acceptanceGreen = Color(uiColor: .systemGreen)
    private let acceptanceForeground = Color.black

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - controlSize - inset * 2)
            let progress = travel > 0 ? min(1, offset / travel) : 0
            let accentProgress = Double(progress)
            let filledWidth = controlSize + inset * 2 + offset

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .systemRed).opacity(0.16 * (1 - accentProgress)))

                Capsule()
                    .fill(acceptanceGreen.opacity(0.22 + 0.78 * accentProgress))
                    .frame(width: filledWidth)
                    .clipped()

                ZStack {
                    recoveryLabel
                        .foregroundStyle(Color.secondary)
                        .opacity(1 - Double(progress) * 0.72)

                    recoveryLabel
                        .foregroundStyle(acceptanceForeground)
                        .mask {
                            HStack(spacing: 0) {
                                Rectangle().frame(width: filledWidth)
                                Spacer(minLength: 0)
                            }
                        }
                }
                .compositingGroup()

                Image(systemName: completing ? "checkmark" : "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        accentProgress > 0.5 || completing
                            ? acceptanceForeground
                            : Color.white
                    )
                    .frame(width: controlSize, height: controlSize)
                    .background {
                        Circle().fill(Color(uiColor: .systemRed))
                        Circle()
                            .fill(acceptanceGreen)
                            .opacity(completing ? 1 : accentProgress)
                    }
                    .overlay {
                        Circle()
                            .stroke(acceptanceGreen.opacity(accentProgress), lineWidth: 1.5)
                    }
                    .offset(x: inset + offset)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
            .overlay {
                ZStack {
                    Capsule()
                        .stroke(
                            Color(uiColor: .systemRed).opacity(0.3 * (1 - accentProgress)),
                            lineWidth: 0.5
                        )
                    Capsule()
                        .stroke(
                            acceptanceGreen.opacity(accentProgress),
                            lineWidth: 0.75 + progress * 0.75
                        )
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !completing else { return }
                        offset = min(max(0, value.translation.width), travel)
                        let currentProgress = travel > 0 ? offset / travel : 0
                        let crossed = currentProgress >= 0.72
                        if crossed && !crossedFeedbackPoint {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        crossedFeedbackPoint = crossed
                    }
                    .onEnded { _ in
                        guard !completing else { return }
                        let currentProgress = travel > 0 ? offset / travel : 0
                        if currentProgress >= 0.88 {
                            completing = true
                            withAnimation(.easeOut(duration: 0.16)) { offset = travel }
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                if !accept() {
                                    completing = false
                                    crossedFeedbackPoint = false
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        offset = 0
                                    }
                                }
                            }
                        } else {
                            crossedFeedbackPoint = false
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                offset = 0
                            }
                        }
                    }
            )
        }
        .frame(maxWidth: 520)
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Принять приглашение")
        .accessibilityHint("Проведите вправо до конца")
        .accessibilityAddTraits(.isButton)
    }

    private var recoveryLabel: some View {
        Text("Проведите, чтобы принять")
            .font(.system(size: 15, weight: .regular))
            .frame(maxWidth: .infinity)
    }
}
#endif
