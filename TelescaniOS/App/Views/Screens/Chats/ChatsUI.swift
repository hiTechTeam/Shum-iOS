import SwiftUI
import Kingfisher
import UIKit

struct ChatContact: Identifiable, Hashable {
    let id: UUID
    let name: String
    let username: String
    let photoURL: String?
    let isNearby: Bool
    let lastMetAt: Date

    init(user: NearbyUser, isNearby: Bool, lastMetAt: Date) {
        id = user.id
        name = user.name
        username = user.username
        photoURL = user.photoURL
        self.isNearby = isNearby
        self.lastMetAt = lastMetAt
    }
}

struct ChatMessage: Identifiable, Hashable {
    enum Direction: Hashable {
        case incoming
        case outgoing
    }

    enum DeliveryState: Hashable {
        case sent
        case delivered
        case read
    }

    let id: UUID
    let text: String
    let sentAt: Date
    let direction: Direction
    let deliveryState: DeliveryState

    init(
        id: UUID = UUID(),
        text: String,
        sentAt: Date = .now,
        direction: Direction,
        deliveryState: DeliveryState = .sent
    ) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.direction = direction
        self.deliveryState = deliveryState
    }
}

struct ChatConversation: Identifiable, Hashable {
    var contact: ChatContact
    var messages: [ChatMessage]
    var lastActivityAt: Date
    var unreadCount: Int

    var id: UUID {
        contact.id
    }
}

final class ChatUIStore: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []

    func messages(for contactID: UUID) -> [ChatMessage] {
        conversations.first(where: { $0.id == contactID })?.messages ?? []
    }

    func send(_ text: String, to contact: ChatContact) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        upsertConversation(with: contact)
        guard let index = conversations.firstIndex(where: { $0.id == contact.id }) else {
            return
        }

        let message = ChatMessage(
            text: trimmed,
            direction: .outgoing,
            deliveryState: .sent
        )
        conversations[index].messages.append(message)
        conversations[index].lastActivityAt = message.sentAt
        sortConversations()
    }

    func refresh() async {
        await Task.yield()
    }

    private func upsertConversation(with contact: ChatContact) {
        if let index = conversations.firstIndex(where: { $0.id == contact.id }) {
            conversations[index].contact = contact
        } else {
            conversations.append(
                ChatConversation(
                    contact: contact,
                    messages: [],
                    lastActivityAt: .now,
                    unreadCount: 0
                )
            )
        }

        sortConversations()
    }

    private func sortConversations() {
        conversations.sort { $0.lastActivityAt > $1.lastActivityAt }
    }
}

struct ChatsListView: View {
    @ObservedObject var store: ChatUIStore
    let openChat: (ChatContact) -> Void

    var body: some View {
        chatsList
            .navigationTitle(Inc.Tabs.chats.localized)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var chatsList: some View {
        List {
            listContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await store.refresh()
        }
        .overlay {
            emptyState
        }
        .background(Color.tsBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private var listContent: some View {
        if !store.conversations.isEmpty {
            ForEach(store.conversations) { conversation in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openChat(conversation.contact)
                } label: {
                    ChatConversationRow(
                        conversation: conversation
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(
                    EdgeInsets(
                        top: 9,
                        leading: 18,
                        bottom: 9,
                        trailing: 18
                    )
                )
                .listRowBackground(Color.tsBackground)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 84 }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.conversations.isEmpty {
            ContentUnavailableView(
                Inc.Chats.emptyTitle.localized,
                systemImage: "bubble.left.and.bubble.right",
                description: Text(Inc.Chats.emptyMessage.localized)
            )
            .allowsHitTesting(false)
        }
    }
}

private struct ChatConversationRow: View {
    let conversation: ChatConversation

    private var lastMessage: ChatMessage? {
        conversation.messages.last
    }

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatarView(
                contact: conversation.contact,
                size: 54
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.contact.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if lastMessage?.direction == .outgoing {
                        ChatDeliveryMarks(
                            state: lastMessage?.deliveryState ?? .sent,
                            fontSize: 9
                        )
                    }

                    Text(chatListDate(conversation.lastActivityAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lastMessage?.text ?? Inc.Chats.newConversation.localized)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 20)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func chatListDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct ChatConversationView: View {
    let contact: ChatContact
    @ObservedObject var store: ChatUIStore
    let isNearby: Bool
    let lastMetAt: Date

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    private var messages: [ChatMessage] {
        store.messages(for: contact.id)
    }

    private var expiresAt: Date {
        lastMetAt.addingTimeInterval(EncounterHistoryPolicy.retention)
    }

    var body: some View {
        ZStack {
            ChatWallpaper()
                .ignoresSafeArea()

            messagesContent
        }
        .overlay(alignment: .top) {
            if !isNearby {
                availabilityPanel
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if isChatAvailable(at: context.date) {
                    composer
                } else {
                    expiredComposer
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    Text(
                        isNearby
                            ? Inc.Chats.nearbyWithYou.localized
                            : Inc.Chats.recentlyMet.localized
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                ChatAvatarView(
                    contact: contact,
                    size: 38
                )
                .accessibilityLabel(contact.name)
            }
        }
    }

    private var messagesContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        if messages.isEmpty {
                            ContentUnavailableView(
                                Inc.Chats.noMessagesTitle.localized,
                                systemImage: "bubble.left",
                                description: Text(
                                    Inc.Chats.noMessagesMessage.localized
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .frame(
                                minHeight: max(
                                    0,
                                    geometry.size.height - (isNearby ? 0 : 80)
                                )
                            )
                        } else {
                            ChatDaySeparator(title: Inc.Chats.today.localized)
                                .padding(.bottom, 5)

                            ForEach(messages) { message in
                                ChatMessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, isNearby ? 14 : 86)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await store.refresh()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isComposerFocused = false
                }
                .onAppear {
                    scrollToLastMessage(using: proxy, animated: false)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToLastMessage(using: proxy, animated: true)
                }
            }
        }
    }

    private var availabilityPanel: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ChatAvailabilityStatus(
                expiresAt: expiresAt,
                now: context.date
            )
        }
        .padding(.horizontal, 36)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Menu {
                Button { } label: {
                    Label(Inc.Chats.photo.localized, systemImage: "photo")
                }

                Button { } label: {
                    Label(Inc.Chats.camera.localized, systemImage: "camera")
                }

                Button { } label: {
                    Label(Inc.Chats.file.localized, systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .tint(.primary)
            .accessibilityLabel(Inc.Chats.attachment.localized)

            TextField(
                Inc.Chats.messagePlaceholder.localized,
                text: $draft,
                axis: .vertical
            )
            .font(.system(size: 15))
            .lineLimit(1...4)
            .frame(minHeight: 38, alignment: .center)
            .focused($isComposerFocused)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.send)
            .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        canSendMessage
                            ? Color.accentColor
                            : Color(uiColor: .systemGray),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessage)
            .accessibilityLabel(Inc.Chats.send.localized)
        }
        .padding(6)
        .modifier(ChatComposerGlassModifier())
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background {
            LinearGradient(
                colors: [.clear, Color.tsBackground.opacity(0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var canSendMessage: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expiredComposer: some View {
        Text(Inc.Chats.waitForNextMeeting.localized)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .background {
                LinearGradient(
                    colors: [.clear, Color.tsBackground.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private func sendMessage() {
        let message = draft
        guard isChatAvailable(at: .now),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        draft = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.send(message, to: contact)
    }

    private func isChatAvailable(at date: Date) -> Bool {
        isNearby || date < expiresAt
    }

    private func scrollToLastMessage(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let lastID = messages.last?.id else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

private struct ChatComposerGlassModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            Color.white.opacity(0.12),
                            lineWidth: 0.5
                        )
                }
        }
    }
}

private struct ChatWallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.tsBackground

            Rectangle()
                .fill(
                    ImagePaint(
                        image: Image("ChatDoodleWallpaper"),
                        scale: 0.22
                    )
                )
                .opacity(colorScheme == .dark ? 0.36 : 0.30)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChatAvailabilityStatus: View {
    let expiresAt: Date
    let now: Date

    private var remaining: TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    private var isExpired: Bool {
        remaining <= 0
    }

    private var progress: Double {
        min(1, remaining / EncounterHistoryPolicy.retention)
    }

    private var remainingText: String {
        let totalMinutes = Int(ceil(remaining / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                isExpired
                    ? Inc.Chats.timeExpired.localized
                    : Inc.Chats.timeRemaining.localized
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                ProgressView(value: progress)
                    .tint(.white)

                Text(remainingText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    private var isOutgoing: Bool {
        message.direction == .outgoing
    }

    private var timeText: String {
        message.sentAt.formatted(date: .omitted, time: .shortened)
    }

    private var bubbleWidth: CGFloat {
        let maximumBubbleWidth: CGFloat = 276
        let horizontalPadding: CGFloat = 28
        let maximumTextWidth = maximumBubbleWidth - horizontalPadding
        let font = UIFont.systemFont(ofSize: 15)
        let text = message.text as NSString
        let naturalTextWidth = ceil(
            text.size(withAttributes: [.font: font]).width
        )
        let measuredTextWidth = ceil(
            text.boundingRect(
                with: CGSize(
                    width: maximumTextWidth,
                    height: .greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).width
        )
        let metadataWidth = ceil(
            (timeText as NSString).size(
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10)
                ]
            ).width
        ) + (isOutgoing ? 18 : 0)

        return min(
            maximumBubbleWidth,
            max(72, max(min(naturalTextWidth, measuredTextWidth), metadataWidth)
                + horizontalPadding)
        )
    }

    var body: some View {
        HStack {
            if isOutgoing {
                Spacer(minLength: 72)
            }

            VStack(
                alignment: isOutgoing ? .trailing : .leading,
                spacing: 5
            ) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(timeText)
                        .font(.system(size: 10))
                        .foregroundStyle(
                            isOutgoing
                                ? Color.white.opacity(0.72)
                                : Color.secondary
                        )

                    if isOutgoing {
                        ChatDeliveryMarks(
                            state: message.deliveryState,
                            fontSize: 8,
                            tint: Color.white.opacity(0.78)
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: bubbleWidth, alignment: .leading)
            .background(
                isOutgoing
                    ? Color(uiColor: .systemBlue)
                    : Color(uiColor: .secondarySystemBackground),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: isOutgoing ? 16 : 5,
                    bottomTrailingRadius: isOutgoing ? 5 : 16,
                    topTrailingRadius: 16,
                    style: .continuous
                )
            )

            if !isOutgoing {
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChatDaySeparator: View {
    let title: String

    var body: some View {
        HStack(spacing: 13) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 0.5)

            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 0.5)
        }
    }
}

private struct ChatDeliveryMarks: View {
    let state: ChatMessage.DeliveryState
    var fontSize: CGFloat
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: -5) {
            Image(systemName: "checkmark")

            if state != .sent {
                Image(systemName: "checkmark")
            }
        }
        .font(.system(size: fontSize, weight: .bold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

private struct ChatAvatarView: View {
    let contact: ChatContact
    let size: CGFloat

    private var imageURL: URL? {
        guard let photoURL = contact.photoURL else { return nil }
        return URL(string: photoURL)
    }

    var body: some View {
        Group {
            if let imageURL {
                KFImage(imageURL)
                    .placeholder { placeholder }
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.43))
                    .foregroundStyle(.secondary)
            }
    }
}
