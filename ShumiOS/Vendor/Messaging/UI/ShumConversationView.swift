#if os(iOS)
import SwiftUI
import BitFoundation

private struct ShumAvatarToolbar<Content: View>: ToolbarContent {
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

private struct ShumComposerSurface: ViewModifier {
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


struct ShumConversationView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    @State private var draft = ""
    @State private var showPeerProfile = false
    @State private var replyingTo: ShumMessage?
    @State private var typingPauseTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @State private var atBottom = true
    @State private var scrollCommand: ShumTimelineCommand?
    private var messages: [ShumMessage] { runtime.conversation(peer.id) }
    private var name: String { runtime.displayName(peer) }
    private var invitationPhase: ShumInvitationPhase {
        runtime.invitationPhase(for: peer.id)
    }

    var body: some View {
        let conversation = messages
        GeometryReader { geometry in
            ZStack {
                ShumConversationTimeline(
                    items: conversation.indices.map { timelineItem(at: $0, in: conversation) },
                    storageKey: "shum.chat.position.\(runtime.permanent?.ownCard.id ?? "local").\(peer.id.id)",
                    appearanceKey: "\(palette.accentUIColor)-\(palette.colorScheme)",
                    command: scrollCommand,
                    contentInsets: geometry.safeAreaInsets,
                    bottomChanged: { atBottom = $0 },
                    tapped: { inputFocused = false }
                ) { index, width in
                    messageRow(
                        at: index,
                        in: conversation,
                        width: width
                    )
                }
                .ignoresSafeArea(.container, edges: .vertical)
                if conversation.isEmpty {
                    VStack(spacing: 12) {
                        ShumAvatar(name: name, size: 70, imageData: runtime.profile(for: peer.id)?.avatar)
                        Text(emptyTitle).font(.headline)
                        if let emptyMessage {
                            Text(emptyMessage).font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { runtime.openConversation(peer.id) }
        .onDisappear {
            typingPauseTask?.cancel()
            runtime.setTyping(false, for: peer.id)
            runtime.openConversation(nil)
        }
        .background(ShumChatCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if runtime.isTyping(peer.id) {
                        ShumTypingIndicator()
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
            ShumAvatarToolbar {
                Button { inputFocused = false; showPeerProfile = true } label: {
                    ShumAvatar(name: name, size: 34, imageData: runtime.profile(for: peer.id)?.avatar)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Профиль собеседника")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer.overlay(alignment: .top) {
                if !atBottom && !conversation.isEmpty {
                    HStack {
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            scrollCommand = ShumTimelineCommand(target: .bottom)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .modifier(ShumComposerSurface())
                        .accessibilityLabel("К последнему сообщению")
                        .accessibilityIdentifier("shum.scrollToBottom")
                        .padding(.trailing, 3)
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 20)
                    .offset(y: -44)
                }
            }
        }
        .sheet(isPresented: $showPeerProfile) {
            ShumPeerProfileSheet(runtime: runtime, peer: peer)
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
                    .accessibilityIdentifier("shum.messageInput")
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
                        scrollCommand = ShumTimelineCommand(target: .bottom)
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
                .accessibilityIdentifier("shum.sendMessage")
            }
        }
        .frame(maxWidth: 520, minHeight: 46)
        .modifier(ShumComposerSurface())
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

    private func beginReply(to message: ShumMessage) {
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

    private func replyAuthor(_ reference: ShumReplyReference) -> String {
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
    private func timelineItem(at index: Int, in conversation: [ShumMessage]) -> ShumTimelineItem {
        let message = conversation[index]
        var revision = Hasher()
        revision.combine(message.text)
        revision.combine(message.date)
        revision.combine(message.outgoing)
        revision.combine(message.status)
        revision.combine(message.deliveryLabel)
        revision.combine(message.waitingForConnection)
        revision.combine(message.reply)
        revision.combine(index > 0 ? conversation[index - 1].date : nil)
        revision.combine(index > 0 ? conversation[index - 1].outgoing : nil)
        revision.combine(index + 1 < conversation.count ? conversation[index + 1].date : nil)
        revision.combine(index + 1 < conversation.count ? conversation[index + 1].outgoing : nil)
        return ShumTimelineItem(id: message.id, revision: revision.finalize())
    }

    private func messageRow(
        at index: Int,
        in conversation: [ShumMessage],
        width: CGFloat
    ) -> some View {
        let message = conversation[index]
        let previous = index > 0 ? conversation[index - 1] : nil
        let next = index + 1 < conversation.count ? conversation[index + 1] : nil
        let continues = next.map { $0.outgoing == message.outgoing && $0.date.timeIntervalSince(message.date) <= 60 } ?? false
        let sameDay = previous.map { Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? false
        return VStack(spacing: 0) {
            if !sameDay {
                Text(dayTitle(message.date)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill).opacity(0.5), in: Capsule())
                    .padding(.top, 16).padding(.bottom, 18)
            }
            ShumMessageBubble(message: message,
                showsTail: !continues,
                maximumWidth: min(width * 0.82, 440),
                replyAuthor: message.reply.map(replyAuthor),
                retry: { runtime.retry(message) },
                reply: { beginReply(to: message) },
                openReply: { scrollCommand = ShumTimelineCommand(target: .message($0)) })
                .padding(.top, sameDay && previous?.outgoing != message.outgoing ? 10 : 3)
        }
        .padding(.horizontal, 10)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.day().month(.wide))
    }
}


#endif
