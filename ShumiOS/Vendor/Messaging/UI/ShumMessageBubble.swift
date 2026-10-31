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
/// Names and avatars shown next to reactions, so it is clear who left each one.
struct ShumReactionPeople {
    var myName = ""
    var myAvatar: Data?
    var peerName = ""
    var peerAvatar: Data?
}

struct ShumMessageBubble: View {
    let message: ShumMessage
    var showsTail = true
    let maximumWidth: CGFloat
    var replyAuthor: String?
    var retry: () -> Void = {}
    var reply: () -> Void = {}
    /// Where an own message can be deleted from; the menu offers them.
    var deleteChoices: [ShumMenuChoice] = []
    /// Withdraws an own message from everyone, as in the open chat.
    var withdraw: (() -> Void)?
    /// The author's avatar column and name in a group chat. They sit inside
    /// the hold and swipe area, so the whole message moves together.
    var leading: AnyView?
    var header: AnyView?
    /// Nil where the message cannot take reactions, such as an archived chat.
    var react: ((ShumReaction) -> Void)?
    var reactionPeople = ShumReactionPeople()
    var openReply: (String) -> Void = { _ in }
    /// Reads a photo's bytes when its row is shown, and opens it full screen.
    var loadPhoto: ((String) async -> UIImage?)?
    var cachedPhoto: ((String) -> UIImage?)?
    var openPhoto: ((UIImage) -> Void)?
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
            .accessibilityLabel(
                Text(
                    String.localizedFormat(
                        "%@: %@, %@%@".localized,
                        message.outgoing ? "Вы".localized : "Собеседник".localized,
                        message.text,
                        message.date.formatted(date: .omitted, time: .shortened),
                        message.outgoing ? ", " + statusDescription : ""
                    )
                )
            )
            .accessibilityValue(reactionsDescription)
            .accessibilityAction(named: "Ответить".localized, reply)
            .accessibilityAction(named: "Скопировать".localized) { UIPasteboard.general.string = message.text }
            .accessibilityActions {
                if let withdraw {
                    Button("Удалить у всех".localized, action: withdraw)
                }
                ForEach(deleteChoices.indices, id: \.self) { index in
                    Button(deleteChoices[index].title, action: deleteChoices[index].action)
                }
                if let react, let mine = message.myReaction {
                    Button("Убрать реакцию".localized) { react(mine) }
                }
            }
            // In the open chat: how many saw it, under the ticks. The eye
            // stays put at the trailing edge while the count grows leftwards.
            if let views = message.views, views > 0 {
                HStack(spacing: 3) {
                    Text("\(views)").monospacedDigit()
                    Image(systemName: "eye").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .accessibilityLabel(String.localizedFormat("Просмотров: %@".localized, "\(views)"))
            }
            if message.outgoing, let label = message.deliveryLabel, label == "В очереди".localized || label.hasPrefix("Передаётся".localized) {
                Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            if message.outgoing && message.waitingForConnection {
                Label("Ожидаем связь".localized, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if message.outgoing, message.deliveryLabel == "Отменено".localized {
                Text("Отменено после блокировки".localized).font(.caption).foregroundStyle(.secondary)
            }
            if message.outgoing, message.deliveryLabel != "Отменено".localized, case .failed = message.status {
                Button(action: retry) {
                    Label("Не доставлено · Повторить".localized, systemImage: "arrow.clockwise")
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

    @ViewBuilder
    private var bubbleContent: some View {
        if let sticker = message.sticker {
            stickerContent(sticker)
        } else if let photo = message.photo {
            photoContent(photo)
        } else {
            textContent
        }
    }

    /// Without a caption the photo stands alone with the time on it; with
    /// one, the bubble holds the photo and the caption under it.
    @ViewBuilder
    private func photoContent(_ photo: ShumMessagePhoto) -> some View {
        let width = min(maximumWidth, 260)
        if message.text.isEmpty {
            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
                ShumMessagePhotoView(messageID: message.id, photo: photo, width: width,
                                     cached: cachedPhoto, load: loadPhoto, open: openPhoto) {
                    metadataPill
                }
                if hasReactions { reactionChips }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Edge to edge: the bubble's own corners round the photo.
                ShumMessagePhotoView(messageID: message.id, photo: photo, width: width, radius: 0,
                                     cached: cachedPhoto, load: loadPhoto, open: openPhoto) { EmptyView() }
                Group {
                    if hasReactions {
                        ShumReactedBubbleLayout(fills: true) {
                            Text(message.text).font(.body).foregroundStyle(.primary)
                            reactionChips
                            metadata
                        }
                    } else {
                        ShumBubbleLayout(inline: !message.text.contains("\n"), fills: true) {
                            Text(message.text).font(.body).foregroundStyle(.primary)
                            metadata
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(width: width, alignment: .leading)
            .padding(.bottom, 8)
            .clipShape(bubbleShape)
            .modifier(
                ShumMessageBubbleSurface(
                    shape: bubbleShape,
                    tint: bubbleColor,
                    highlight: themePalette.accent.opacity(quoteHighlightOpacity)
                )
            )
        }
    }

    /// A sticker stands alone, large and without a bubble, with its time
    /// and reactions under it.
    private func stickerContent(_ sticker: String) -> some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
            Image(uiImage: ShumReactionArt.image(sticker: sticker, size: 150))
                .interpolation(.none)
                .frame(width: 150, height: 150)
                .accessibilityLabel(message.text)
            HStack(spacing: 6) {
                if hasReactions { reactionChips }
                metadataPill
            }
        }
    }

    /// The time, and for own messages their receipt, on top of a photo.
    private var metadataPill: some View {
        HStack(spacing: 4) {
            Text(message.date, style: .time).monospacedDigit()
            if message.outgoing {
                ShumDeliveryReceipt(status: message.status, color: .white, readColor: .white)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Color.black.opacity(0.45), in: Capsule())
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reference = message.reply {
                Button {
                    openReply(reference.messageID)
                } label: {
                    HStack(spacing: 8) {
                        Capsule().fill(themePalette.accent).frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyAuthor ?? "Сообщение".localized)
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

            if hasReactions {
                ShumReactedBubbleLayout {
                    Text(message.text).font(.body).foregroundStyle(.primary)
                    reactionChips
                    metadata
                }
            } else {
                ShumBubbleLayout(inline: !message.text.contains("\n")) {
                    Text(message.text).font(.body).foregroundStyle(.primary)
                    metadata
                }
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
            cancelSending: withdraw ?? (deleteChoices.isEmpty ? nil : {}),
            cancelTitle: withdraw == nil ? "Удалить".localized : "Удалить у всех".localized,
            deleteChoices: deleteChoices,
            reaction: message.myReaction, react: react,
            dragChanged: updateReplyDrag, dragEnded: finishReplyDrag) {
                if leading == nil && header == nil {
                    bubbleContent
                } else {
                    HStack(alignment: .bottom, spacing: 6) {
                        leading
                        VStack(alignment: .leading, spacing: 2) {
                            header
                            bubbleContent
                        }
                    }
                }
            }
    }

    private var hasReactions: Bool {
        message.myReaction != nil || message.theirReaction != nil || !message.groupReactions.isEmpty
    }

    private var reactionsDescription: String {
        let names = message.groupReactions.isEmpty
            ? [message.theirReaction, message.myReaction].compactMap { $0 }.map(ShumReactionArt.name(for:))
            : message.groupReactions.map { "\(ShumReactionArt.name(for: $0.reaction)) \($0.people.count)" }
        return names.isEmpty ? "" : String.localizedFormat("Реакции: %@".localized, names.joined(separator: ", "))
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(message.date, style: .time).monospacedDigit()
            if message.outgoing { receipt }
        }.font(.system(size: 11)).foregroundStyle(metadataColor)
    }

    /// One chip per reaction with the avatar of whoever left it. The same
    /// reaction from both people shares one chip with both avatars.
    private var reactionChips: some View {
        HStack(spacing: 6) {
            if !message.groupReactions.isEmpty {
                ForEach(message.groupReactions, id: \.self) { groupChip($0) }
            } else if let theirs = message.theirReaction, theirs == message.myReaction {
                reactionChip(theirs, people: [false, true])
            } else {
                if let theirs = message.theirReaction { reactionChip(theirs, people: [false]) }
                if let mine = message.myReaction { reactionChip(mine, people: [true]) }
            }
        }
    }

    /// `people` holds `true` for the user. The user's chip is outlined and
    /// takes the reaction back when tapped; the contact's sets the same reaction.
    private func reactionChip(_ reaction: ShumReaction, people: [Bool]) -> some View {
        let mine = people.contains(true)
        return Button {
            react?(reaction)
        } label: {
            HStack(spacing: 4) {
                ShumReactionIcon(reaction: reaction, size: 18)
                HStack(spacing: -6) {
                    ForEach(people.indices, id: \.self) { index in
                        let me = people[index]
                        ShumAvatar(name: me ? reactionPeople.myName : reactionPeople.peerName, size: 18,
                                   imageData: me ? reactionPeople.myAvatar : reactionPeople.peerAvatar)
                            .overlay(Circle().stroke(bubbleColor, lineWidth: index > 0 ? 1.5 : 0))
                    }
                }
            }
            .padding(.leading, 6).padding(.trailing, 3).padding(.vertical, 3)
            .background(Capsule().fill(mine ? themePalette.accent.opacity(message.outgoing ? 0.32 : 0.22)
                                            : Color.primary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(mine ? themePalette.accent : .clear, lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(react != nil)
    }

    /// A reaction left by several people: up to three faces, then a count.
    /// Tapping sets the same reaction, or takes back the user's own.
    private func groupChip(_ group: ShumGroupReaction) -> some View {
        Button {
            react?(group.reaction)
        } label: {
            HStack(spacing: 4) {
                ShumReactionIcon(reaction: group.reaction, size: 18)
                HStack(spacing: -6) {
                    ForEach(Array(group.people.prefix(3).enumerated()), id: \.offset) { index, person in
                        ShumAvatar(name: person.name, size: 18, imageData: person.avatar)
                            .overlay(Circle().stroke(bubbleColor, lineWidth: index > 0 ? 1.5 : 0))
                    }
                }
                if group.people.count > 3 {
                    Text("+\(group.people.count - 3)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6).padding(.trailing, group.people.count > 3 ? 6 : 3).padding(.vertical, 3)
            .background(Capsule().fill(group.mine ? themePalette.accent.opacity(message.outgoing ? 0.32 : 0.22)
                                                   : Color.primary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(group.mine ? themePalette.accent : .clear, lineWidth: 1.2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(react != nil)
    }

    /// Offered exactly while the clock icon shows the message is in transit.
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
    private var receipt: some View {
        ShumDeliveryReceipt(status: message.status, color: metadataColor, readColor: themePalette.accent)
            .font(.system(size: 10, weight: .semibold))
    }
    private var statusDescription: String {
        if message.waitingForConnection { return "Ожидаем связь".localized }
        return ShumDeliveryReceipt.description(for: message.status)
    }
}

/// Measures text before allocating the bubble; short text and time share a line.
/// Wrapped text gets a trailing metadata line, which never overlaps the message.
struct ShumBubbleLayout: Layout {
    var inline: Bool
    /// Takes the whole width offered, so the time sits at the trailing edge
    /// under a photo wider than the caption.
    var fills = false
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
        let size = fits ? CGSize(width: text.width + meta.width + 8, height: max(text.height, meta.height))
            : CGSize(width: max(text.width, meta.width), height: text.height + meta.height + 2)
        guard fills, let width = proposal.width else { return size }
        return CGSize(width: max(size.width, width), height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (text, meta, _) = metrics(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(text))
        subviews[1].place(at: CGPoint(x: bounds.maxX - meta.width, y: bounds.maxY - meta.height), proposal: ProposedViewSize(meta))
    }
}

/// Text on top; below it the reaction chips on the leading side and the time
/// on the trailing side. The bubble is only as wide as its widest row.
struct ShumReactedBubbleLayout: Layout {
    /// Takes the whole width offered, as `ShumBubbleLayout.fills`.
    var fills = false
    private let spacing: CGFloat = 6
    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (text: CGSize, chips: CGSize, meta: CGSize, width: CGFloat) {
        let limit = max(1, proposal.width ?? 300)
        let chips = roundedUp(subviews[1].sizeThatFits(.unspecified))
        let meta = roundedUp(subviews[2].sizeThatFits(.unspecified))
        let ideal = roundedUp(subviews[0].sizeThatFits(.unspecified))
        let text = roundedUp(subviews[0].sizeThatFits(ProposedViewSize(width: min(limit, ideal.width), height: nil)))
        return (text, chips, meta, min(limit, max(text.width, chips.width + 10 + meta.width)))
    }
    private func roundedUp(_ size: CGSize) -> CGSize {
        CGSize(width: ceil(size.width), height: ceil(size.height))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = metrics(proposal, subviews)
        let width = fills ? max(m.width, proposal.width ?? m.width) : m.width
        return CGSize(width: width, height: m.text.height + spacing + max(m.chips.height, m.meta.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(m.text))
        let row = max(m.chips.height, m.meta.height), y = bounds.minY + m.text.height + spacing
        subviews[1].place(at: CGPoint(x: bounds.minX, y: y + (row - m.chips.height) / 2), proposal: ProposedViewSize(m.chips))
        subviews[2].place(at: CGPoint(x: bounds.maxX - m.meta.width, y: y + (row - m.meta.height) / 2), proposal: ProposedViewSize(m.meta))
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
