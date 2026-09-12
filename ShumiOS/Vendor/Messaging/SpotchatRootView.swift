#if os(iOS)
import SwiftUI
import BitFoundation

private struct SpotchatAvatarToolbar<Content: View>: ToolbarContent {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                content.frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
            }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) { content }
        }
    }
}

struct SpotchatAvatar: View {
    let name: String
    let size: CGFloat
    var nearby = false
    var imageData: Data?
    private var color: Color {
        let palette: [Color] = [.blue, .indigo, .teal, .purple, .orange]
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[index]
    }
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: size * 0.36, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .top, endPoint: .bottom), in: Circle())
            .overlay {
                if let data = imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if nearby {
                    Circle().fill(.green).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                }
            }.accessibilityHidden(true)
    }
}

struct SpotchatConversationView: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    @State private var draft = ""
    @State private var showPeerProfile = false
    @FocusState private var inputFocused: Bool
    @State private var atBottom = true
    private var messages: [SpotchatMessage] { runtime.conversation(peer.id) }
    private var name: String { runtime.displayName(peer) }

    var body: some View {
        let conversation = messages
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if conversation.isEmpty {
                            VStack(spacing: 12) {
                                SpotchatAvatar(name: name, size: 70, imageData: runtime.profile(for: peer.id)?.avatar)
                                Text("Скажите привет").font(.headline)
                                Text(runtime.isNearby(peer.id) ? "\(name) рядом.\nДля разговора достаточно Bluetooth." : "Напишите первое сообщение.\nОно дождётся возможности доставки.")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 10))
                        }
                        ForEach(Array(conversation.enumerated()), id: \.element.id) { index, message in
                            let previous = index > 0 ? conversation[index - 1] : nil
                            let next = index + 1 < conversation.count ? conversation[index + 1] : nil
                            let continues = next.map { $0.outgoing == message.outgoing && $0.date.timeIntervalSince(message.date) <= 60 } ?? false
                            let sameDay = previous.map { Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? false
                            if !sameDay {
                                Text(dayTitle(message.date)).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Color(.tertiarySystemFill).opacity(0.5), in: Capsule())
                                    .padding(.top, 16).padding(.bottom, 18)
                            }
                            SpotchatMessageBubble(message: message,
                                showsTail: !continues,
                                maximumWidth: min(geometry.size.width * 0.82, 440),
                                retry: { runtime.retry(message) })
                                .padding(.top, sameDay && previous?.outgoing != message.outgoing ? 10 : 3)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 10).id("conversation-bottom")
                    }.padding(.horizontal, 10)
                        .background(GeometryReader { content in
                            Color.clear.preference(key: SpotchatBottomKey.self,
                                value: content.frame(in: .named("conversation")).maxY)
                        })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                .coordinateSpace(name: "conversation")
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(SpotchatBottomKey.self) { atBottom = $0 <= geometry.size.height + 80 }
                .onChange(of: messages.count) { _ in
                    if atBottom || messages.last?.outgoing == true { scrollToBottom(proxy) }
                }
                .onChange(of: inputFocused) { focused in if focused { scrollToBottom(proxy) } }
                .onChange(of: geometry.size.height) { _ in
                    if atBottom || inputFocused { scrollToBottom(proxy) }
                }
                .onAppear {
                    runtime.openConversation(peer.id)
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .onDisappear { runtime.openConversation(nil) }
            }
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(runtime.isNearby(peer.id) ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(runtime.isBlocked(peer.id) ? "Заблокирован" : (runtime.isNearby(peer.id) ? "Рядом" : "Не рядом")).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
            SpotchatAvatarToolbar {
                Button { inputFocused = false; showPeerProfile = true } label: {
                    SpotchatAvatar(name: name, size: 34, imageData: runtime.profile(for: peer.id)?.avatar)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Профиль собеседника")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(isPresented: $showPeerProfile) {
            SpotchatPeerProfileSheet(runtime: runtime, peer: peer)
        }
        .onChange(of: showPeerProfile) { visible in
            runtime.openConversation(!visible && runtime.chatPeers.contains(where: { $0.id == peer.id }) ? peer.id : nil)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if runtime.isLegacyOnly(peer.id) {
                Text("История сохранена. Добавьте этого человека по QR-коду или найдите рядом, чтобы продолжить переписку.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(12)
            } else if runtime.isBlocked(peer.id) { Text("Контакт заблокирован").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 0) {
                TextField("Сообщение", text: $draft, prompt: Text("Сообщение").foregroundColor(Color(.secondaryLabel)), axis: .vertical)
                    .font(.body).lineLimit(1...5).focused($inputFocused)
                    .textFieldStyle(.plain).disabled(runtime.isBlocked(peer.id))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .accessibilityIdentifier("spotchat.messageInput")
                    #if DEBUG && targetEnvironment(simulator)
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewKeyboard") {
                            draft = "Да, всё отлично"
                            inputFocused = true
                        }
                    }
                    #endif

                }
                .frame(minHeight: 46)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    guard canSend else { return }
                    if runtime.send(draft, to: peer.id) { draft = "" }
                } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 21))
                        .rotationEffect(.degrees(45))
                        .foregroundStyle(.black).frame(width: 46, height: 46)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!canSend)
                    .accessibilityLabel("Отправить сообщение").accessibilityIdentifier("spotchat.sendMessage")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
    private var canSend: Bool { !runtime.isLegacyOnly(peer.id) && !runtime.isBlocked(peer.id) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (runtime.permanent != nil || runtime.isNearby(peer.id)) }
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.day().month(.wide))
    }
}

private struct SpotchatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SpotchatMessageBubble: View {
    let message: SpotchatMessage
    var showsTail = true
    let maximumWidth: CGFloat
    var retry: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
            SpotchatBubbleLayout(inline: !message.text.contains("\n")) {
                Text(message.text).font(.body).foregroundStyle(.primary)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    Text(message.date, style: .time).monospacedDigit()
                    if message.outgoing { receipt }
                }.font(.system(size: 11)).foregroundStyle(metadataColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(bubbleColor, in: SpotchatBubbleShape(outgoing: message.outgoing, tail: showsTail))
            // The cap lives OUTSIDE the background: a short message keeps its intrinsic bubble width.
            .frame(maxWidth: maximumWidth, alignment: message.outgoing ? .trailing : .leading)
            .contextMenu { Button { UIPasteboard.general.string = message.text } label: { Label("Скопировать", systemImage: "doc.on.doc") } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(message.outgoing ? "Вы" : "Собеседник"): \(message.text), \(message.date.formatted(date: .omitted, time: .shortened))\(message.outgoing ? ", " + statusDescription : "")")
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
    }
    private var bubbleColor: Color {
        message.outgoing
            ? (colorScheme == .dark ? Color(red: 0.08, green: 0.24, blue: 0.16) : Color(red: 0.83, green: 0.97, blue: 0.86))
            : Color(.secondarySystemBackground)
    }
    private var metadataColor: Color {
        message.outgoing ? (colorScheme == .dark ? Color(red: 0.56, green: 0.76, blue: 0.63) : Color(red: 0.24, green: 0.46, blue: 0.31)) : .secondary
    }
    @ViewBuilder private var receipt: some View {
        switch message.status {
        case .read:
            SpotchatDoubleCheck().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
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
struct SpotchatBubbleLayout: Layout {
    var inline: Bool
    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGSize, CGSize, Bool) {
        let limit = max(1, proposal.width ?? 300)
        let meta = subviews[1].sizeThatFits(.unspecified)
        let ideal = subviews[0].sizeThatFits(.unspecified)
        let fits = inline && ideal.width + meta.width + 8 <= limit
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: min(limit, ideal.width), height: nil))
        return (text, meta, fits)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (text, meta, fits) = metrics(proposal, subviews)
        return fits ? CGSize(width: text.width + meta.width + 8, height: max(text.height, meta.height))
            : CGSize(width: max(text.width, meta.width), height: text.height + meta.height + 2)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (text, meta, _) = metrics(proposal, subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(text))
        subviews[1].place(at: CGPoint(x: bounds.maxX - meta.width, y: bounds.maxY - meta.height), proposal: ProposedViewSize(meta))
    }
}

struct SpotchatBubbleShape: Shape {
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

private struct SpotchatDoubleCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 4, y: 9)); p.addLine(to: CGPoint(x: 12, y: 1))
        p.move(to: CGPoint(x: 8, y: 7)); p.addLine(to: CGPoint(x: 10, y: 9)); p.addLine(to: CGPoint(x: 16, y: 3))
        return p
    }
}
#endif
