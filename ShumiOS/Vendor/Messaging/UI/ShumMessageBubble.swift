#if os(iOS)
import SwiftUI
import BitFoundation
private struct ShumMessageBubbleSurface: ViewModifier {
    let shape: ShumBubbleShape
    let tint: Color
    let highlight: Color

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(tint)
                    shape.fill(highlight)
                }
                .allowsHitTesting(false)
            }
    }
}
struct ShumMessageBubble: View {
    let message: ShumMessage
    var showsTail = true
    let maximumWidth: CGFloat
    var replyAuthor: String?
    var retry: () -> Void = {}
    var reply: () -> Void = {}
    var openReply: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shumThemePalette) private var themePalette
    @State private var horizontalOffset: CGFloat = 0
    @State private var crossedReplyThreshold = false
    @State private var quoteHighlightOpacity: CGFloat = 0
    @State private var quoteHighlightGeneration = 0

    private let replyThreshold: CGFloat = 52

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
            ZStack(alignment: .trailing) {
                replyGestureIndicator
                bubble
                    .frame(maxWidth: maximumWidth, alignment: message.outgoing ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
                    .offset(x: horizontalOffset)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.outgoing ? "Вы" : "Собеседник"): \(message.text), \(message.date.formatted(date: .omitted, time: .shortened))\(message.outgoing ? ", " + statusDescription : "")")
            .accessibilityAction(named: "Ответить", reply)
            .accessibilityAction(named: "Скопировать") { UIPasteboard.general.string = message.text }
            if message.outgoing, let label = message.deliveryLabel, label == "В очереди" || label.hasPrefix("Передаётся") {
                Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            if message.outgoing && message.waitingForConnection {
                Label("Ожидаем связь", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if message.outgoing, message.deliveryLabel == "Отменено" {
                Text("Отменено после блокировки").font(.caption).foregroundStyle(.secondary)
            }
            if message.outgoing, message.deliveryLabel != "Отменено", case .failed = message.status {
                Button(action: retry) {
                    Label("Не доставлено · Повторить", systemImage: "arrow.clockwise")
                        .font(.system(size: 12)).foregroundStyle(.red).padding(.vertical, 8)
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: message.outgoing ? .trailing : .leading)
            .onReceive(NotificationCenter.default.publisher(for: .shumHighlightMessage)) { note in
                guard note.object as? String == message.id else { return }
                quoteHighlightGeneration &+= 1
            }
            .task(id: quoteHighlightGeneration) {
                guard quoteHighlightGeneration > 0 else { return }
                withAnimation(.easeInOut(duration: 0.24)) {
                    quoteHighlightOpacity = 0.20
                }
                try? await Task.sleep(nanoseconds: 360_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.88)) {
                    quoteHighlightOpacity = 0
                }
            }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reference = message.reply {
                Button {
                    openReply(reference.messageID)
                } label: {
                    HStack(spacing: 8) {
                        Capsule().fill(themePalette.accent).frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyAuthor ?? "Сообщение")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(themePalette.accent)
                            Text(reference.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(colorScheme == .dark ? 0.16 : 0.05),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            ShumBubbleLayout(inline: !message.text.contains("\n")) {
                Text(message.text).font(.body).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(message.date, style: .time).monospacedDigit()
                    if message.outgoing { receipt }
                }.font(.system(size: 11)).foregroundStyle(metadataColor)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .modifier(
            ShumMessageBubbleSurface(
                shape: bubbleShape,
                tint: bubbleColor,
                highlight: themePalette.accent.opacity(quoteHighlightOpacity)
            )
        )
    }

    private var bubble: some View {
        ShumMessageContextMenu(shape: bubbleShape, maximumWidth: maximumWidth,
            reply: reply, copy: { UIPasteboard.general.string = message.text },
            dragChanged: updateReplyDrag, dragEnded: finishReplyDrag) {
                bubbleContent
            }
    }

    private var bubbleShape: ShumBubbleShape {
        ShumBubbleShape(outgoing: message.outgoing, tail: showsTail)
    }

    private var replyGestureIndicator: some View {
        let progress = min(1, abs(horizontalOffset) / replyThreshold)
        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(.regularMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
            .scaleEffect(0.72 + 0.28 * progress)
            .opacity(progress)
            .padding(.trailing, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func updateReplyDrag(_ translation: CGFloat) {
        let distance = max(0, -translation)
        let displayedDistance: CGFloat
        if distance <= replyThreshold {
            displayedDistance = distance
        } else {
            let overflow = distance - replyThreshold
            let resistanceLength: CGFloat = 54
            let resistedOverflow = resistanceLength * (1 - 1 / (overflow / resistanceLength * 0.72 + 1))
            displayedDistance = replyThreshold + resistedOverflow
        }
        horizontalOffset = -displayedDistance

        let crossed = abs(horizontalOffset) >= replyThreshold
        if crossed && !crossedReplyThreshold {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.92)
        }
        crossedReplyThreshold = crossed
    }

    private func finishReplyDrag(_ translation: CGFloat, _ completed: Bool) {
        if completed && translation <= -replyThreshold { reply() }
        crossedReplyThreshold = false
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            horizontalOffset = 0
        }
    }
    private var bubbleColor: Color {
        message.outgoing
            ? themePalette.outgoingMessageBubble(for: colorScheme)
            : Color(.secondarySystemBackground)
    }
    private var metadataColor: Color {
        message.outgoing
            ? themePalette.outgoingMessageMetadata(for: colorScheme)
            : .secondary
    }
    @ViewBuilder private var receipt: some View {
        switch message.status {
        case .read:
            ShumDoubleCheck().stroke(themePalette.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 10)
        case .delivered:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "clock").font(.system(size: 10))
        }
    }
    private var statusDescription: String {
        if message.waitingForConnection { return "Ожидаем связь" }
        switch message.status {
        case .read: return "Прочитано"
        case .delivered: return "Доставлено"
        case .failed: return "Не доставлено"
        default: return "Отправляется"
        }
    }
}

/// Measures text before allocating the bubble; short text and time share a line.
/// Wrapped text gets a trailing metadata line, which never overlaps the message.
struct ShumBubbleLayout: Layout {
    var inline: Bool
    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGSize, CGSize, Bool) {
        let limit = max(1, proposal.width ?? 300)
        let meta = roundedUp(subviews[1].sizeThatFits(.unspecified))
        let ideal = roundedUp(subviews[0].sizeThatFits(.unspecified))
        // SwiftUI can re-propose a rounded width after measurement. A fractional
        // difference must not flip an inline message into a narrower two-line one.
        let fits = inline && ideal.width + meta.width + 8 <= limit + 0.5
        let text = roundedUp(subviews[0].sizeThatFits(ProposedViewSize(width: min(limit, ideal.width), height: nil)))
        return (text, meta, fits)
    }
    private func roundedUp(_ size: CGSize) -> CGSize {
        CGSize(width: ceil(size.width), height: ceil(size.height))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (text, meta, fits) = metrics(proposal, subviews)
        return fits ? CGSize(width: text.width + meta.width + 8, height: max(text.height, meta.height))
            : CGSize(width: max(text.width, meta.width), height: text.height + meta.height + 2)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (text, meta, _) = metrics(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(text))
        subviews[1].place(at: CGPoint(x: bounds.maxX - meta.width, y: bounds.maxY - meta.height), proposal: ProposedViewSize(meta))
    }
}

struct ShumBubbleShape: Shape {
    var outgoing: Bool
    var tail: Bool
    func path(in rect: CGRect) -> Path {
        guard tail else { return Path(roundedRect: rect, cornerRadius: 18) }
        let w = rect.width, h = rect.height, r = min(18.0, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r - 3, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - 3, y: r), control: CGPoint(x: w - 3, y: 0))
        p.addLine(to: CGPoint(x: w - 3, y: h - 10))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - 3, y: h - 3))
        p.addQuadCurve(to: CGPoint(x: w - 12, y: h - 4), control: CGPoint(x: w - 7, y: h))
        p.addQuadCurve(to: CGPoint(x: w - 21, y: h), control: CGPoint(x: w - 15, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
        p.closeSubpath()
        if !outgoing { p = p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

struct ShumDoubleCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 4, y: 9)); p.addLine(to: CGPoint(x: 12, y: 1))
        p.move(to: CGPoint(x: 8, y: 7)); p.addLine(to: CGPoint(x: 10, y: 9)); p.addLine(to: CGPoint(x: 16, y: 3))
        return p
    }
}
#endif
