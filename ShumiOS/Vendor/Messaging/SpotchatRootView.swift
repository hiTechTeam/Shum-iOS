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

private struct SpotchatComposerSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }
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
                    Circle().fill(Color(uiColor: .systemGreen)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                }
            }.accessibilityHidden(true)
    }
}

struct SpotchatConversationView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    @State private var draft = ""
    @State private var showPeerProfile = false
    @State private var replyingTo: SpotchatMessage?
    @State private var typingPauseTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @State private var atBottom = true
    private var messages: [SpotchatMessage] { runtime.conversation(peer.id) }
    private var name: String { runtime.displayName(peer) }
    private var invitationPhase: SpotchatInvitationPhase {
        runtime.invitationPhase(for: peer.id)
    }

    var body: some View {
        let conversation = messages
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if conversation.isEmpty {
                            VStack(spacing: 12) {
                                SpotchatAvatar(name: name, size: 70, imageData: runtime.profile(for: peer.id)?.avatar)
                                Text(emptyTitle).font(.headline)
                                if let emptyMessage {
                                    Text(emptyMessage)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
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
                                replyAuthor: message.reply.map(replyAuthor),
                                retry: { runtime.retry(message) },
                                reply: { beginReply(to: message) },
                                openReply: { id in
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                })
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
                .onDisappear {
                    typingPauseTask?.cancel()
                    runtime.setTyping(false, for: peer.id)
                    runtime.openConversation(nil)
                }
            }
        }
        .background(ShumChatCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if runtime.isTyping(peer.id) {
                        SpotchatTypingIndicator()
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 4) {
                            if runtime.isOnline(peer.id) {
                                Circle().fill(Color(uiColor: .systemGreen)).frame(width: 5, height: 5)
                            }
                            Text(presenceText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    }
                }.accessibilityElement(children: .combine)
                    .animation(.easeInOut(duration: 0.18), value: runtime.isTyping(peer.id))
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

    private var presenceText: String {
        if runtime.isBlocked(peer.id) { return "Заблокирован" }
        if runtime.isNearby(peer.id) { return "Рядом · в сети" }
        return runtime.isOnline(peer.id) ? "В сети" : "Не в сети"
    }

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            if runtime.isLegacyOnly(peer.id) {
                lockedCapsule(
                    title: "История сохранена",
                    icon: "lock.fill"
                )
            } else if runtime.isBlocked(peer.id) {
                lockedCapsule(title: "Контакт заблокирован", icon: "lock.fill")
            } else {
                switch invitationPhase {
                case .ready:
                    actionCapsule(
                        title: "Отправить приглашение",
                        color: Color.accentColor,
                        foreground: palette.accentForeground
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        _ = runtime.sendInvitation(to: peer.id)
                    }
                case .outgoingPending:
                    lockedCapsule(title: "Дождитесь подтверждения, после чего начинайте общение")
                case .incomingPending:
                    invitationDecisionControls
                case .accepted:
                    messageComposer
                case .declinedByPeer:
                    lockedCapsule(title: "Общение недоступно", icon: "lock.fill")
                case .declinedLocally:
                    ShumInvitationRecoverySlider {
                        runtime.acceptInvitation(from: peer.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: invitationPhase)
    }

    private var messageComposer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyingTo.outgoing ? "Ответ себе" : "Ответ пользователю \(name)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(replyingTo.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Отменить ответ")
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.top, 8)
                .padding(.bottom, 5)
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Сообщение", text: $draft, prompt: Text("Сообщение").foregroundColor(Color(.secondaryLabel)), axis: .vertical)
                    .font(.body).lineLimit(1...5).focused($inputFocused)
                    .textFieldStyle(.plain)
                    .padding(.leading, 16).padding(.vertical, 12)
                    .accessibilityIdentifier("spotchat.messageInput")
                    #if DEBUG && targetEnvironment(simulator)
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewKeyboard") {
                            draft = "Да, всё отлично"
                            inputFocused = true
                        }
                    }
                    #endif
                    .onChange(of: draft) { value in updateTyping(for: value) }
                Button {
                    guard canSend else { return }
                    if runtime.send(draft, to: peer.id, replyingTo: replyingTo) {
                        typingPauseTask?.cancel()
                        runtime.setTyping(false, for: peer.id)
                        draft = ""
                        withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSend ? palette.accentForeground : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 5).padding(.vertical, 5)
                .accessibilityLabel("Отправить сообщение")
                .accessibilityIdentifier("spotchat.sendMessage")
            }
        }
        .frame(maxWidth: 520, minHeight: 46)
        .modifier(SpotchatComposerSurface())
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.18), value: replyingTo?.id)
    }

    private var invitationDecisionControls: some View {
        HStack(spacing: 10) {
            actionCapsule(
                title: "Отклонить",
                color: Color(uiColor: .systemRed),
                foreground: .black
            ) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                _ = runtime.declineInvitation(from: peer.id)
            }
            actionCapsule(
                title: "Принять",
                color: Color.accentColor,
                foreground: palette.accentForeground
            ) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                _ = runtime.acceptInvitation(from: peer.id)
            }
        }
        .frame(maxWidth: 520)
    }

    private func actionCapsule(
        title: String,
        color: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 46)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(color, in: Capsule())
    }

    private func lockedCapsule(title: String, icon: String? = nil) -> some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon) }
            Text(title)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.center)
        }
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 520, minHeight: 46)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .overlay {
            Capsule().stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var canSend: Bool {
        invitationPhase == .accepted
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (runtime.permanent != nil || runtime.isNearby(peer.id))
    }

    private func beginReply(to message: SpotchatMessage) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            replyingTo = message
        }
        inputFocused = true
    }

    private func updateTyping(for value: String) {
        typingPauseTask?.cancel()
        let active = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        runtime.setTyping(active, for: peer.id)
        guard active else { return }
        typingPauseTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { runtime.setTyping(false, for: peer.id) }
        }
    }

    private func replyAuthor(_ reference: SpotchatReplyReference) -> String {
        if let ownID = runtime.permanent?.ownCard.id, reference.senderID == ownID { return "Вы" }
        if reference.senderID == "self" { return "Вы" }
        return name
    }

    private var emptyTitle: String {
        switch invitationPhase {
        case .ready: "Начните общение"
        case .outgoingPending: "Приглашение отправлено"
        case .incomingPending: "Приглашение в чат"
        case .accepted: "Можете начинать общение"
        case .declinedByPeer: "Пользователь \(name) отклонил ваш запрос"
        case .declinedLocally: "Приглашение отклонено"
        }
    }

    private var emptyMessage: String? {
        switch invitationPhase {
        case .ready:
            "Сначала отправьте приглашение."
        case .outgoingPending:
            "Ожидаем подтверждения."
        case .incomingPending:
            "\(name) хочет начать с вами общение."
        case .accepted:
            "Чат доступен."
        case .declinedByPeer:
            "Общение пока недоступно."
        case .declinedLocally:
            "Проведите стрелку вправо, если передумаете."
        }
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.day().month(.wide))
    }
}

private struct SpotchatTypingIndicator: View {
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

private struct ShumInvitationRecoverySlider: View {
    @Environment(\.shumThemePalette) private var palette
    let accept: () -> Bool
    @State private var offset: CGFloat = 0
    @State private var crossedFeedbackPoint = false
    @State private var completing = false

    private let controlSize: CGFloat = 38
    private let inset: CGFloat = 4

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
                    .fill(Color.accentColor.opacity(0.22 + 0.78 * accentProgress))
                    .frame(width: filledWidth)
                    .clipped()

                ZStack {
                    recoveryLabel
                        .foregroundStyle(Color.secondary)
                        .opacity(1 - Double(progress) * 0.72)

                    recoveryLabel
                        .foregroundStyle(palette.accentForeground)
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
                            ? palette.accentForeground
                            : Color.white
                    )
                    .frame(width: controlSize, height: controlSize)
                    .background {
                        Circle().fill(Color(uiColor: .systemRed))
                        Circle()
                            .fill(Color.accentColor)
                            .opacity(completing ? 1 : accentProgress)
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.accentColor.opacity(accentProgress), lineWidth: 1.5)
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
                            Color.accentColor.opacity(accentProgress),
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

private struct SpotchatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SpotchatMessageBubble: View {
    let message: SpotchatMessage
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

    private let replyThreshold: CGFloat = 52

    var body: some View {
        VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
            ZStack(alignment: .trailing) {
                replyGestureIndicator
                bubble
                    .offset(x: horizontalOffset)
                    .simultaneousGesture(replyDragGesture)
            }
            .frame(maxWidth: maximumWidth, alignment: message.outgoing ? .trailing : .leading)
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

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reference = message.reply {
                Button {
                    openReply(reference.messageID)
                } label: {
                    HStack(spacing: 8) {
                        Capsule().fill(Color.accentColor).frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyAuthor ?? "Сообщение")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
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

            SpotchatBubbleLayout(inline: !message.text.contains("\n")) {
                Text(message.text).font(.body).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(message.date, style: .time).monospacedDigit()
                    if message.outgoing { receipt }
                }.font(.system(size: 11)).foregroundStyle(metadataColor)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(bubbleColor, in: bubbleShape)
        .contentShape(.interaction, bubbleShape)
        .contentShape(.contextMenuPreview, bubbleShape)
        .contextMenu {
            Button(action: reply) {
                Label("Ответить", systemImage: "arrowshape.turn.up.left")
                    .foregroundStyle(.white)
            }
            .tint(.white)
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
                    .foregroundStyle(.white)
            }
            .tint(.white)
        }
    }

    private var bubbleShape: SpotchatBubbleShape {
        SpotchatBubbleShape(outgoing: message.outgoing, tail: showsTail)
    }

    private var replyGestureIndicator: some View {
        let progress = min(1, abs(horizontalOffset) / replyThreshold)
        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(progress >= 1 ? Color.black : Color.accentColor)
            .frame(width: 32, height: 32)
            .background(progress >= 1 ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
            .scaleEffect(0.72 + 0.28 * progress)
            .opacity(progress)
            .padding(.trailing, 4)
            .accessibilityHidden(true)
    }

    private var replyDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.width < 0,
                      abs(value.translation.width) > abs(value.translation.height) * 1.15 else {
                    return
                }

                updateReplyDrag(value.translation.width)
            }
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.15
                finishReplyDrag(value.translation.width, isHorizontal)
            }
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

struct SpotchatDoubleCheck: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 4, y: 9)); p.addLine(to: CGPoint(x: 12, y: 1))
        p.move(to: CGPoint(x: 8, y: 7)); p.addLine(to: CGPoint(x: 10, y: 9)); p.addLine(to: CGPoint(x: 16, y: 3))
        return p
    }
}
#endif
