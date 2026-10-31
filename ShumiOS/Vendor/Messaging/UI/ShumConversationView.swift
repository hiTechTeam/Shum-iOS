#if os(iOS)
import SwiftUI
import PhotosUI
import BitFoundation

private struct ShumAvatarToolbar<Content: View>: ToolbarContent {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .navigationBarTrailing) {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                content.buttonStyle(.plain).frame(width: 44, height: 44)
            }
        }
    }
}

private struct ShumComposerSurface: ViewModifier {
    /// Liquid Glass casts a shadow onto content passing underneath. Controls
    /// floating over the history use the plain material instead.
    var glass = true
    private let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), glass {
            // The glass lies behind the controls, not around them: a menu
            // grows out of the glass holding its button, and would take the
            // whole capsule with it.
            content.background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}


/// How many new messages wait below, over the scroll-down button.
struct ShumNewBelowBadge: View {
    let count: Int
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(palette.accentForeground)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(palette.accent, in: Capsule())
            .accessibilityLabel(String.localizedFormat("Новых сообщений: %@".localized, "\(count)"))
    }
}

/// The send arrow every chat shares: a light arrow in a small circle,
/// dimmed while there is nothing to send.
struct ShumSendButtonLabel: View {
    let enabled: Bool
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(enabled ? palette.accentForeground : Color.secondary)
            .frame(width: 34, height: 34)
            .background(enabled ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
            .padding(.trailing, 6).padding(.vertical, 6).padding(.leading, 3)
            .contentShape(Rectangle())
    }
}

struct ShumConversationView: View {
    @Environment(\.shumThemePalette) private var palette
    @Environment(\.shumPresentPeerPhoto) private var presentPeerPhoto
    @Environment(\.shumPresentChatPhoto) private var presentChatPhoto
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    @State private var draft = ShumComposerDraft()
    /// Where the composer's capsule starts, so the chevron sits right above it.
    @State private var capsuleInset: CGFloat = 8
    @State private var showProtection = false
    @State private var replyingTo: ShumMessage?
    @State private var typingPauseTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @State private var atBottom = true
    @State private var scrollCommand: ShumTimelineCommand?
    @State private var choosingPhoto = false
    @State private var takingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    /// A chosen photo waiting in the capsule until the send arrow.
    @State private var pendingPhoto: ShumPreparedPhoto?
    @State private var pendingPreview: UIImage?
    /// The messages there were when the chat left its end; those that came
    /// since count over the scroll-down button.
    @State private var idsWhenScrolledUp: Set<String>?
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
    private var showsScrollToBottom: Bool {
        !atBottom && !messages.isEmpty
    }

    var body: some View {
        let conversation = messages
        GeometryReader { geometry in
            ZStack {
                ShumConversationTimeline(
                    items: conversation.indices.map { timelineItem(at: $0, in: conversation) } + typingItem,
                    storageKey: "shum.chat.position.\(runtime.permanent?.ownCard.id ?? "local").\(peer.id.id)",
                    appearanceKey: "\(palette.accentUIColor)-\(palette.colorScheme)",
                    command: scrollCommand,
                    contentInsets: geometry.safeAreaInsets,
                    composer: AnyView(composer),
                    accessory: showsScrollToBottom ? AnyView(scrollToBottomButton) : nil,
                    accessoryInset: capsuleInset,
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
                    if index < conversation.count {
                        messageRow(
                            at: index,
                            in: conversation,
                            width: width
                        )
                    } else {
                        typingRow
                    }
                }
                // Keep one stable viewport; keyboard avoidance is represented
                // only by the timeline's insets, not a simultaneous frame resize.
                .ignoresSafeArea(.all, edges: .vertical)
                if conversation.isEmpty {
                    VStack(spacing: 12) {
                        Button(action: openPhotoPreview) {
                            ShumAvatar(name: name, size: 70, imageData: runtime.profile(for: peer.id)?.avatar)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Посмотреть фото".localized)
                        .accessibilityIdentifier("shum.invitation.avatar")
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
            runtime.closeConversation(peer.id)
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
        .shumOnChange(of: atBottom) { _, bottom in
            idsWhenScrolledUp = bottom ? nil : Set(messages.map(\.id))
        }
        // The contact starts typing: a chat at its end follows the bubble.
        .shumOnChange(of: runtime.isTyping(peer.id)) { _, typing in
            if typing, atBottom { scrollCommand = ShumTimelineCommand(target: .bottom) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    // Typing shows in the chat itself, as its last row; with
                    // the chat scrolled up that row is out of sight, so here.
                    HStack(spacing: 4) {
                        if typingOutOfSight {
                            ShumPresencePixels(seed: peer.id.id, offColor: Color.secondary.opacity(0.3))
                        }
                        Text(typingOutOfSight ? "печатает".localized : presenceText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }.accessibilityElement(children: .combine)
                    .animation(.easeInOut(duration: 0.18), value: typingOutOfSight)
            }
            ShumAvatarToolbar {
                Button(action: openPhotoPreview) {
                    ShumAvatar(name: name, size: 34, imageData: runtime.profile(for: peer.id)?.avatar)
                        .contentShape(Circle())
                }.foregroundStyle(.primary)
                    .accessibilityLabel("Посмотреть фото".localized)
                    .accessibilityIdentifier("shum.chat.avatar")
            }
        }
        .shumSheet(isPresented: $showProtection) {
            ShumChatProtectionSheet(runtime: runtime, peer: peer)
        }
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

    private var typingOutOfSight: Bool {
        !atBottom && runtime.isTyping(peer.id)
    }

    /// "In chat" means the contact has this conversation open right now.
    private var presenceText: String {
        if runtime.isBlocked(peer.id) { return "Заблокирован".localized }
        // Someone typing has this chat open even before the presence mark arrives.
        let inChat = runtime.isInChat(peer.id) || runtime.isTyping(peer.id)
        let nearby = runtime.isNearby(peer.id)
        // How far, next to "nearby", once Bluetooth measures it.
        let near = runtime.distanceMeters(for: peer.id).map {
            "рядом".localized + " · " + String(format: "distanceMetersFormat".localized, $0)
        } ?? "рядом".localized
        if inChat && nearby { return "в чате".localized + " · " + near }
        if inChat { return "в чате".localized }
        if nearby { return near }
        return "не в чате".localized
    }

    private static let composerSpace = "shum.composer"

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 8) {
            if offersAddContact {
                addContactShortcut
            }
            composerControl
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.composerSpace)).minY } action: {
                    capsuleInset = $0
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        // The timeline pins the composer to the keyboard layout guide.
        // A fixed gap avoids a second, mismatched animation of the composer.
        .padding(.bottom, 8)
        .coordinateSpace(name: Self.composerSpace)
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

    /// Messages from the contact that came since the chat left its end.
    private var newBelow: Int {
        guard let ids = idsWhenScrolledUp else { return 0 }
        return messages.filter { !$0.outgoing && !ids.contains($0.id) }.count
    }

    /// While the contact types, the chat ends in a bubble with their avatar
    /// and Shum's pixels, as in the open chat.
    private var typingItem: [ShumTimelineItem] {
        runtime.isTyping(peer.id) ? [ShumTimelineItem(id: "typing", revision: 0)] : []
    }

    private var typingRow: some View {
        HStack(spacing: 8) {
            ShumAvatar(name: name, size: 26, imageData: runtime.profile(for: peer.id)?.avatar)
            ShumPresencePixels(seed: peer.id.id, offColor: Color.secondary.opacity(0.3))
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String.localizedFormat("%@ печатает".localized, name))
    }

    private var scrollToBottomButton: some View {
        VStack(spacing: 6) {
            if newBelow > 0 { ShumNewBelowBadge(count: newBelow) }
            scrollButton
        }
    }

    private var scrollButton: some View {
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
        .modifier(ShumComposerSurface(glass: false))
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
            if let pendingPreview {
                HStack(spacing: 10) {
                    Image(uiImage: pendingPreview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Фото".localized)
                    Spacer(minLength: 0)
                    Button {
                        self.pendingPhoto = nil
                        self.pendingPreview = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Убрать фото".localized)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.top, 10)
            }
            if let replyingTo {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyingTo.outgoing ? "Ответ себе".localized : String.localizedFormat("Ответ пользователю %@".localized, name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(replyingTo.preview)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.replyingTo = nil
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

            HStack(alignment: .bottom, spacing: 0) {
                attachButton
                TextField("Сообщение".localized, text: draftBinding, prompt: Text("Сообщение".localized).foregroundColor(Color(.secondaryLabel)), axis: .vertical)
                    .font(.body).lineLimit(1...5).focused($inputFocused)
                    .textFieldStyle(.plain)
                    .padding(.trailing, 4).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { inputFocused = true })
                    .accessibilityIdentifier("shum.messageInput")
                    .onChange(of: draft.text) { value in updateTyping(for: value) }
                Button {
                    guard canSend else { return }
                    if let pendingPhoto {
                        sendPending(pendingPhoto)
                    } else if runtime.send(draft.text, to: peer.id, replyingTo: replyingTo) {
                        typingPauseTask?.cancel()
                        runtime.setTyping(false, for: peer.id)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            draft.clearAfterSending()
                        }
                        scrollCommand = ShumTimelineCommand(target: .bottom)
                        self.replyingTo = nil
                    }
                } label: {
                    ShumSendButtonLabel(enabled: canSend)
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
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    runtime.error = "Не получилось открыть фото".localized
                    return
                }
                attachPhoto(image)
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            ShumCameraPicker { attachPhoto($0) }
                .ignoresSafeArea()
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewKeyboard") {
                draft.update("Да, всё отлично", from: draft.revision)
                inputFocused = true
            }
        }
        #endif
    }

    /// "+" with the system menu: Photo, and Camera where there is one.
    private var attachButton: some View {
        ShumAttachButton(
            accent: palette.accentUIColor,
            accentForeground: UIColor(palette.accentForeground),
            choosePhoto: { choosingPhoto = true },
            takePhoto: ShumCameraPicker.isAvailable ? { takingPhoto = true } : nil
        )
        .frame(width: 46, height: 46)
    }

    /// Prepares a chosen or taken photo off the main thread and puts it in
    /// the capsule; it leaves only with the send arrow.
    private func attachPhoto(_ image: UIImage) {
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                ShumPhotoPreparation.prepare(image)
            }.value
            guard let prepared else {
                runtime.error = "Не получилось подготовить фото".localized
                return
            }
            pendingPhoto = prepared
            pendingPreview = UIImage(data: prepared.jpeg)
            inputFocused = true
        }
    }

    /// Sends the photo in the capsule; text in the field is its caption.
    private func sendPending(_ photo: ShumPreparedPhoto) {
        guard runtime.sendPhoto(photo, caption: draft.text, to: peer.id) else { return }
        pendingPhoto = nil
        pendingPreview = nil
        typingPauseTask?.cancel()
        runtime.setTyping(false, for: peer.id)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { draft.clearAfterSending() }
        scrollCommand = ShumTimelineCommand(target: .bottom)
        replyingTo = nil
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
            && (pendingPhoto != nil || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        // The quote bar appears at once: the capsule's UIKit host resizes in
        // the same frame, so content cannot slide in from below.
        replyingTo = message
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
        // A photo coming in turns its placeholder into the picture.
        revision.combine(message.photo)
        // A reaction changes the row height, so the table must re-measure it.
        revision.combine(message.myReaction)
        revision.combine(message.theirReaction)
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
                cancelSending: { runtime.cancelSending(message) },
                react: runtime.isLegacyOnly(message.peerID) ? nil : { runtime.toggleReaction($0, on: message) },
                reactionPeople: message.myReaction == nil && message.theirReaction == nil ? ShumReactionPeople()
                    : ShumReactionPeople(myName: runtime.nickname, myAvatar: runtime.profiles.own.avatar,
                                         peerName: name, peerAvatar: runtime.profile(for: peer.id)?.avatar),
                openReply: { scrollCommand = ShumTimelineCommand(target: .message($0)) },
                loadPhoto: { await runtime.photo(for: $0) },
                cachedPhoto: { runtime.cachedPhoto(for: $0) },
                openPhoto: { image in
                    inputFocused = false
                    presentChatPhoto?(ShumChatPhoto(
                        image: image,
                        title: message.outgoing ? "Вы".localized : name,
                        subtitle: message.date.formatted(date: .abbreviated, time: .shortened)))
                })
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
