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
    @Environment(\.shumPresentPeerPhoto) private var presentPeerPhoto
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    @State private var draft = ShumComposerDraft()
    @State private var showProtection = false
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
    private var peerCard: ShumContactCard? {
        runtime.permanent?.card(for: peer.id)
    }
    private var offersAddContact: Bool {
        peerCard != nil && !runtime.isContact(peer.id) && !runtime.isBlocked(peer.id)
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
                    bottomChanged: { bottom in
                        #if DEBUG && targetEnvironment(simulator)
                        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewScrollButton") {
                            atBottom = false
                            return
                        }
                        #endif
                        atBottom = bottom
                    },
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
        .safeAreaInset(edge: .top, spacing: 0) {
            ShumChatProtectionBanner(
                state: runtime.chatProtection(for: peer.id)
            ) {
                inputFocused = false
                showProtection = true
            }
        }
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
                    .shumHiddenFromSystemCapture(true)
            }
            ShumAvatarToolbar {
                Button(action: openPhotoPreview) {
                    ShumAvatar(name: name, size: 34, imageData: runtime.profile(for: peer.id)?.avatar)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Посмотреть фото".localized)
                    .disabled(runtime.profile(for: peer.id)?.avatar == nil)
                    .shumHiddenFromSystemCapture(true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .sheet(isPresented: $showProtection) {
            ShumChatProtectionSheet(runtime: runtime, peer: peer)
        }
        // Keep message rows protected during a navigation pop transition.
        .shumHiddenFromSystemCapture(true)
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewScrollButton") {
                atBottom = false
            }
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewPeerPhoto") {
                openPhotoPreview()
            }
        }
        #endif
    }

    private func openPhotoPreview() {
        guard let avatar = runtime.profile(for: peer.id)?.avatar,
              let image = UIImage(data: avatar) else { return }
        inputFocused = false
        presentPeerPhoto?(image)
    }

    private var presenceText: String {
        if runtime.isBlocked(peer.id) { return "Заблокирован".localized }
        if runtime.isNearby(peer.id) { return "Рядом · в сети".localized }
        return runtime.isOnline(peer.id) ? "В сети".localized : "Не в сети".localized
    }

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            if offersAddContact {
                addContactShortcut
            }
            composerControl
                .overlay(alignment: .topTrailing) {
                    if !atBottom && !messages.isEmpty {
                        scrollToBottomButton
                            .padding(.trailing, 3)
                            .offset(y: -48)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        // SwiftUI's keyboard safe area moves this inset with the keyboard.
        // A fixed gap avoids a second, mismatched animation of the composer.
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: invitationPhase)
    }

    @ViewBuilder
    private var composerControl: some View {
        if runtime.isLegacyOnly(peer.id) {
            lockedCapsule(title: "История сохранена".localized, icon: "lock.fill")
        } else if runtime.isBlocked(peer.id) {
            lockedCapsule(title: "Контакт заблокирован".localized, icon: "lock.fill")
        } else {
            switch invitationPhase {
            case .ready:
                actionCapsule(
                    title: "Отправить приглашение".localized,
                    color: Color.accentColor,
                    foreground: palette.accentForeground
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    _ = runtime.sendInvitation(to: peer.id)
                }
            case .outgoingPending:
                lockedCapsule(title: "Дождитесь подтверждения, после чего начинайте общение".localized)
            case .incomingPending:
                invitationDecisionControls
            case .accepted:
                messageComposer
            case .declinedByPeer:
                lockedCapsule(title: "Общение недоступно".localized, icon: "lock.fill")
            case .declinedLocally:
                ShumInvitationRecoverySlider {
                    runtime.acceptInvitation(from: peer.id)
                }
            }
        }
    }

    private var scrollToBottomButton: some View {
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
        .accessibilityLabel("К последнему сообщению".localized)
        .accessibilityIdentifier("shum.scrollToBottom")
    }

    private var addContactShortcut: some View {
        Button {
            guard let peerCard else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            _ = runtime.addContact(peerCard, source: "conversation")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(.secondary)
                Text("Не в контактах".localized)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Добавить".localized)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 13, weight: .regular))
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Добавить пользователя в контакты".localized)
    }

    private var messageComposer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyingTo.outgoing ? "Ответ себе".localized : String.localizedFormat("Ответ пользователю %@".localized, name))
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
                    .accessibilityLabel("Отменить ответ".localized)
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .padding(.top, 8)
                .padding(.bottom, 5)
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Сообщение".localized, text: draftBinding, prompt: Text("Сообщение".localized).foregroundColor(Color(.secondaryLabel)), axis: .vertical)
                    .font(.body).lineLimit(1...5).focused($inputFocused)
                    .textFieldStyle(.plain)
                    .padding(.leading, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { inputFocused = true })
                    .accessibilityIdentifier("shum.messageInput")
                    .onChange(of: draft.text) { value in updateTyping(for: value) }
                Button {
                    guard canSend else { return }
                    if runtime.send(draft.text, to: peer.id, replyingTo: replyingTo) {
                        typingPauseTask?.cancel()
                        runtime.setTyping(false, for: peer.id)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            draft.clearAfterSending()
                        }
                        scrollCommand = ShumTimelineCommand(target: .bottom)
                        withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(canSend ? palette.accentForeground : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                        .padding(.trailing, 5).padding(.vertical, 5)
                        .padding(.leading, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Отправить сообщение".localized)
                .accessibilityIdentifier("shum.sendMessage")
            }
        }
        .frame(maxWidth: 520, minHeight: 46)
        .background {
            // The field's transparent padding is not a reliable tap target.
            // Catch taps on the rest of the capsule underneath its controls.
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                .onTapGesture { inputFocused = true }
        }
        .modifier(ShumComposerSurface())
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.18), value: replyingTo?.id)
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewKeyboard") {
                draft.update("Да, всё отлично", from: draft.revision)
                inputFocused = true
            }
        }
        #endif
    }

    private var invitationDecisionControls: some View {
        HStack(spacing: 10) {
            actionCapsule(
                title: "Отклонить".localized,
                color: Color(uiColor: .systemRed),
                foreground: .black
            ) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                _ = runtime.declineInvitation(from: peer.id)
            }
            actionCapsule(
                title: "Принять".localized,
                color: Color(uiColor: .systemGreen),
                foreground: .black
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
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (runtime.permanent != nil || runtime.isNearby(peer.id))
    }

    private var draftBinding: Binding<String> {
        let revision = draft.revision
        return Binding(
            get: { draft.text },
            set: { draft.update($0, from: revision) }
        )
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
        if let ownID = runtime.permanent?.ownCard.id, reference.senderID == ownID { return "Вы".localized }
        if reference.senderID == "self" { return "Вы".localized }
        return name
    }

    private var emptyTitle: String {
        switch invitationPhase {
        case .ready: "Начните общение".localized
        case .outgoingPending: "Приглашение отправлено".localized
        case .incomingPending: "Приглашение в чат".localized
        case .accepted: "Можете начинать общение".localized
        case .declinedByPeer: String.localizedFormat("Пользователь %@ отклонил ваш запрос".localized, name)
        case .declinedLocally: "Приглашение отклонено".localized
        }
    }

    private var emptyMessage: String? {
        switch invitationPhase {
        case .ready:
            "Сначала отправьте приглашение.".localized
        case .outgoingPending:
            "Ожидаем подтверждения.".localized
        case .incomingPending:
            String.localizedFormat("%@ хочет начать с вами общение.".localized, name)
        case .accepted:
            "Чат доступен.".localized
        case .declinedByPeer:
            "Общение пока недоступно.".localized
        case .declinedLocally:
            "Проведите стрелку вправо, если передумаете.".localized
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
        if Calendar.current.isDateInToday(date) { return "Сегодня".localized }
        if Calendar.current.isDateInYesterday(date) { return "Вчера".localized }
        return date.formatted(.dateTime.day().month(.wide))
    }
}


#endif
