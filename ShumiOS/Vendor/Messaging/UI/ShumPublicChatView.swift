#if os(iOS)
import SwiftUI
import BitFoundation

/// The open chat with everyone nearby over Bluetooth: no contacts or
/// invitations, whoever is on the mesh reads it. It works like a chat:
/// quotes, reactions and withdrawing own notes, on the same timeline.
struct ShumPublicChatView: View {
    @ObservedObject var runtime: ShumRuntime
    /// Opens a chat with someone from the list of people here.
    var open: (ShumUIRoute) -> Void = { _ in }
    @Environment(\.shumThemePalette) private var palette
    @State private var draft = ShumComposerDraft()
    @FocusState private var focused: Bool
    @State private var showsPeople = false
    @State private var showsAbout = false
    @State private var replyingTo: ShumPublicNote?
    @State private var capsuleInset: CGFloat = 8
    @State private var atBottom = true
    @State private var scrollCommand: ShumTimelineCommand?
    @State private var typingPauseTask: Task<Void, Never>?
    /// The notes there were when the chat left its end; those that came
    /// since count over the scroll-down button.
    @State private var idsWhenScrolledUp: Set<String>?
    @Environment(\.scenePhase) private var scenePhase
    /// The header pixels; they stir while anyone nearby types here.
    static let pixelSeed = "public-chat"

    private var store: ShumMessageStore? { runtime.permanent }
    private var notes: [ShumPublicNote] { store?.publicNotes ?? [] }
    private var ownID: String? { store?.ownCard.id }
    /// Everyone else who has the open chat on screen now.
    private var people: [ShumContactCard] {
        (store?.publicPeople ?? []).filter { $0.id != ownID }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
    /// Who types here right now.
    private var writers: [ShumContactCard] {
        var seen = Set<String>()
        return (store?.publicTypers ?? []).filter { $0.id != ownID && seen.insert($0.id).inserted }
    }
    private var trimmed: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        runtime.bluetoothReady && !trimmed.isEmpty && trimmed.utf8.count <= 2000
    }

    var body: some View {
        let notes = notes
        GeometryReader { geometry in
            ZStack {
                ShumConversationTimeline(
                    items: notes.indices.map { item(at: $0, in: notes) } + typingItem,
                    storageKey: "shum.publicChat.position.\(ownID ?? "local")",
                    appearanceKey: "\(palette.accentUIColor)-\(palette.colorScheme)",
                    command: scrollCommand,
                    contentInsets: geometry.safeAreaInsets,
                    composer: AnyView(composer),
                    accessory: !atBottom && !notes.isEmpty ? AnyView(scrollToBottomButton) : nil,
                    accessoryInset: capsuleInset,
                    bottomChanged: { atBottom = $0 },
                    tapped: { focused = false }
                ) { index, width in
                    if index < notes.count {
                        row(at: index, in: notes, width: width)
                    } else {
                        typingRow
                    }
                }
                .ignoresSafeArea(.all, edges: .vertical)
                if notes.isEmpty { emptyState }
            }
        }
        .onAppear {
            store?.markPublicChatRead()
            store?.setPublicPresence(scenePhase == .active)
        }
        .shumOnChange(of: atBottom) { _, bottom in
            idsWhenScrolledUp = bottom ? nil : Set(notes.map(\.id))
        }
        // Someone starts typing: their bubble joins the end of the chat, so
        // a chat already at its end follows it out from behind the capsule.
        .shumOnChange(of: writers.map(\.id)) { old, new in
            guard atBottom, !new.isEmpty, old != new else { return }
            scrollCommand = ShumTimelineCommand(target: .bottom)
        }
        .onDisappear {
            typingPauseTask?.cancel()
            store?.setPublicTyping(false)
            store?.setPublicPresence(false)
        }
        // In the background the chat is not on screen.
        .shumOnChange(of: scenePhase) { _, phase in store?.setPublicPresence(phase == .active) }
        .shumOnChange(of: notes.last?.id) { _, _ in store?.markPublicChatRead() }
        .background(ShumChatCanvas().ignoresSafeArea())
        // Stays put like the encryption line under the chat list.
        .safeAreaInset(edge: .top, spacing: 0) { aboutLine }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showsPeople = true } label: {
                    // Who is in the chat now, that is, nearby on the mesh.
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        if !people.isEmpty {
                            Text("\(people.count)").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
                .tint(.primary)
                .accessibilityLabel(String.localizedFormat("Рядом: %@".localized, "\(people.count)"))
            }
        }
        .shumSheet(isPresented: $showsPeople) {
            ShumPublicPeopleSheet(
                people: people,
                writers: Set(writers.map(\.id)),
                contacts: Set(store?.state.contacts.map(\.id) ?? []),
                avatar: avatar(for:),
                distance: distance
            ) { card in
                // Added if new, then their chat, as when adding by a link.
                guard let peer = runtime.addContact(card, source: "publicChat") else { return }
                showsPeople = false
                open(.conversation(peer))
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .shumSheet(isPresented: $showsAbout) {
            ShumPublicChatAbout()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("Общий чат".localized).font(.system(size: 17, weight: .semibold))
            // Typing shows as the chat's last row; with the chat scrolled up
            // that row is out of sight, so here.
            if !atBottom && !writers.isEmpty {
                HStack(spacing: 4) {
                    ShumPresencePixels(seed: Self.pixelSeed, offColor: Color.secondary.opacity(0.3))
                    Text(writerNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String.localizedFormat("Пишут: %@".localized, writerNames))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: !atBottom && !writers.isEmpty)
    }

    /// The first two who type and how many more.
    private var writerNames: String {
        let names = writers.prefix(2).map(\.name).joined(separator: ", ")
        let more = writers.count - 2
        return more > 0 ? "\(names) +\(more)" : names
    }

    /// Who is typing shows as the last row of the chat while it lasts.
    private var typingItem: [ShumTimelineItem] {
        guard !writers.isEmpty else { return [] }
        var revision = Hasher()
        for card in writers { revision.combine(card.id) }
        return [ShumTimelineItem(id: "public-typing", revision: revision.finalize())]
    }

    /// Names on top, the first two and how many more; below them a bubble
    /// with their avatars and Shum's pixels, as an incoming note would sit.
    private var typingRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(writerNames)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 12)
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(writers.prefix(3), id: \.id) { card in
                        ShumAvatar(name: card.name, size: 26, imageData: avatar(for: card))
                            .overlay(Circle().stroke(Color(.secondarySystemBackground), lineWidth: 2))
                    }
                }
                if writers.count > 3 {
                    Text("+\(writers.count - 3)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                ShumPresencePixels(seed: Self.pixelSeed, offColor: Color.secondary.opacity(0.3))
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String.localizedFormat("Пишут: %@".localized, writerNames))
    }

    private var aboutLine: some View {
        Button {
            focused = false
            showsAbout = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("Видят все, кто рядом · Bluetooth".localized)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        Text("Здесь пока тихо. Напишите первым: сообщение увидят все, у кого рядом открыт Shum.".localized)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    // MARK: Timeline

    private func message(for note: ShumPublicNote) -> ShumMessage {
        let mine = note.reactions.first { $0.personID == ownID }?.reaction
        var groups: [ShumGroupReaction] = []
        for reaction in ShumReaction.allCases {
            let marks = note.reactions.filter { $0.reaction == reaction }
            guard !marks.isEmpty else { continue }
            groups.append(ShumGroupReaction(
                reaction: reaction,
                people: marks.map { mark in
                    let card = mark.card
                    return ShumReactionPerson(name: card?.name ?? "", avatar: card.flatMap(avatar(for:)))
                },
                mine: marks.contains { $0.personID == ownID }
            ))
        }
        // Seen by someone: two ticks; the eye says how many.
        var message = ShumMessage(id: note.id, peerID: note.card.peerID, text: note.text, date: note.date,
                                  outgoing: note.outgoing,
                                  status: note.views > 0 ? .read(by: "", at: note.date) : .delivered(to: "", at: note.date),
                                  reply: note.reply, myReaction: mine, groupReactions: groups)
        message.views = note.outgoing ? note.views : nil
        return message
    }

    private func item(at index: Int, in notes: [ShumPublicNote]) -> ShumTimelineItem {
        let note = notes[index]
        var revision = Hasher()
        revision.combine(note.text)
        revision.combine(note.date)
        revision.combine(note.reply)
        revision.combine(note.views)
        for mark in note.reactions {
            revision.combine(mark.personID)
            revision.combine(mark.reaction)
        }
        for neighbour in [index - 1, index + 1] where notes.indices.contains(neighbour) {
            revision.combine(notes[neighbour].card.id)
            revision.combine(notes[neighbour].date)
        }
        return ShumTimelineItem(id: note.id, revision: revision.finalize())
    }

    private func row(at index: Int, in notes: [ShumPublicNote], width: CGFloat) -> some View {
        let note = notes[index]
        let previous = index > 0 ? notes[index - 1] : nil
        let next = index + 1 < notes.count ? notes[index + 1] : nil
        let first = previous.map { !continues($0, note) } ?? true
        let last = next.map { !continues(note, $0) } ?? true
        let sameDay = previous.map { Calendar.current.isDate($0.date, inSameDayAs: note.date) } ?? false
        let incoming = !note.outgoing
        let bubble = ShumMessageBubble(
            message: message(for: note),
            showsTail: last,
            // The avatar column takes 34 points of the row.
            maximumWidth: min(width * 0.78, 420) + (incoming ? 34 : 0),
            replyAuthor: note.reply.map(replyAuthor),
            reply: { beginReply(to: note) },
            withdraw: note.outgoing ? { store?.publicRetract(note) } : nil,
            leading: incoming ? AnyView(authorAvatar(note, shown: last)) : nil,
            header: incoming && first ? AnyView(authorName(note)) : nil,
            react: { reaction in
                let mine = note.reactions.first { $0.personID == ownID }?.reaction
                store?.publicReaction(mine == reaction ? nil : reaction, on: note)
            },
            openReply: { id in
                guard let reply = note.reply else { return }
                scrollCommand = ShumTimelineCommand(target: .message("\(reply.senderID):\(id)"))
            }
        )
        return VStack(spacing: 0) {
            if !sameDay {
                Text(dayTitle(note.date)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill).opacity(0.5), in: Capsule())
                    .padding(.top, 16).padding(.bottom, 18)
            }
            bubble
        }
        .padding(.top, first && sameDay ? 8 : 3)
        .padding(.horizontal, 10)
        // A note counts as seen once it is on screen here.
        .onAppear { if incoming { store?.markPublicSeen(note) } }
    }

    /// The avatar ends a run of one person's notes; earlier ones keep its place.
    @ViewBuilder
    private func authorAvatar(_ note: ShumPublicNote, shown: Bool) -> some View {
        if shown {
            ShumAvatar(name: note.card.name, size: 28, imageData: avatar(for: note.card))
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }

    /// The author, and how far away they are when Bluetooth reaches them directly.
    private func authorName(_ note: ShumPublicNote) -> some View {
        HStack(spacing: 4) {
            Text(note.card.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(nameColor(note.card.id))
        }
        .padding(.leading, 12)
    }

    private func distance(_ card: ShumContactCard) -> Int? {
        store?.distance(for: card).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The same author within five minutes reads as one run of bubbles.
    private func continues(_ earlier: ShumPublicNote, _ later: ShumPublicNote) -> Bool {
        earlier.card.id == later.card.id && earlier.outgoing == later.outgoing
            && later.date.timeIntervalSince(earlier.date) < 300
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Сегодня".localized }
        if Calendar.current.isDateInYesterday(date) { return "Вчера".localized }
        return date.formatted(.dateTime.day().month(.wide))
    }

    private func replyAuthor(_ reference: ShumReplyReference) -> String {
        if reference.senderID == ownID { return "Вы".localized }
        return notes.first { $0.card.id == reference.senderID }?.card.name
            ?? people.first { $0.id == reference.senderID }?.name
            ?? "Сообщение".localized
    }

    /// Notes from others that came since the chat left its end.
    private var newBelow: Int {
        guard let ids = idsWhenScrolledUp else { return 0 }
        return notes.filter { !$0.outgoing && !ids.contains($0.id) }.count
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
        .modifier(ShumPublicComposerSurface())
        .accessibilityLabel("К последнему сообщению".localized)
    }

    // MARK: Composer

    private static let composerSpace = "shum.publicComposer"

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(spacing: 10) {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(replyingTo.outgoing
                             ? "Ответ себе".localized
                             : String.localizedFormat("Ответ пользователю %@".localized, replyingTo.card.name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(replyingTo.text)
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
                .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 5)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(
                    "",
                    text: draftBinding,
                    prompt: Text(runtime.bluetoothReady
                                 ? "Написать всем рядом".localized
                                 : "Включите Bluetooth, чтобы писать".localized)
                        .foregroundColor(Color(.secondaryLabel)),
                    axis: .vertical
                )
                .font(.body).lineLimit(1...5).focused($focused)
                .textFieldStyle(.plain)
                .padding(.leading, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                .disabled(!runtime.bluetoothReady)
                .accessibilityIdentifier("shum.publicInput")
                .onChange(of: draft.text) { value in updateTyping(for: value) }
                Button(action: send) {
                    ShumSendButtonLabel(enabled: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Отправить сообщение".localized)
            }
        }
        .frame(maxWidth: 520, minHeight: 46)
        .background {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                .onTapGesture { focused = true }
        }
        .modifier(ShumPublicComposerSurface())
        .animation(.easeOut(duration: 0.15), value: canSend)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.composerSpace)).minY } action: {
            capsuleInset = $0
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .coordinateSpace(name: Self.composerSpace)
    }

    /// A retired editor may still deliver a late autocorrection; the
    /// revision keeps it from bringing sent text back into the field.
    private var draftBinding: Binding<String> {
        let revision = draft.revision
        return Binding(
            get: { draft.text },
            set: { draft.update($0, from: revision) }
        )
    }

    /// As in a chat: typing starts with text and stops after a pause.
    private func updateTyping(for value: String) {
        typingPauseTask?.cancel()
        let active = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        store?.setPublicTyping(active)
        guard active else { return }
        typingPauseTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { store?.setPublicTyping(false) }
        }
    }

    private func beginReply(to note: ShumPublicNote) {
        // The quote bar appears at once: the capsule's UIKit host resizes in
        // the same frame, so content cannot slide in from below.
        replyingTo = note
        focused = true
    }

    private func send() {
        guard canSend else { return }
        let reply = replyingTo.map {
            ShumReplyReference(messageID: $0.noteID, senderID: $0.card.id, text: String($0.text.prefix(200)))
        }
        store?.broadcast(trimmed, reply: reply)
        typingPauseTask?.cancel()
        store?.setPublicTyping(false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { draft.clearAfterSending() }
        scrollCommand = ShumTimelineCommand(target: .bottom)
        replyingTo = nil
    }

    private func avatar(for card: ShumContactCard) -> Data? {
        store?.avatar(for: card) ?? card.avatarSeed.flatMap(ShumPixelAvatarGenerator.data(seed:))
    }

    /// A steady colour per person, so a name is recognisable down the chat.
    private func nameColor(_ id: String) -> Color {
        let colors: [Color] = [.pink, .cyan, .orange, .purple, .mint, .yellow, .teal, .red, .indigo, .green]
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return colors[hash % colors.count]
    }
}

private struct ShumPublicComposerSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(Color(.separator).opacity(0.35), lineWidth: 0.5) }
        }
    }
}

/// Everyone with the open chat on screen: who it is, how far, whether they
/// write now and whether they are a contact.
private struct ShumPublicPeopleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let people: [ShumContactCard]
    let writers: Set<String>
    let contacts: Set<String>
    let avatar: (ShumContactCard) -> Data?
    let distance: (ShumContactCard) -> Int?
    let write: (ShumContactCard) -> Void
    @State private var shown: ShumContactCard?

    var body: some View {
        NavigationStack {
            List {
                if people.isEmpty {
                    Text("В общем чате пока никого. Люди появятся, когда откроют его у себя рядом с вами.".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(people.sorted { writers.contains($0.id) && !writers.contains($1.id) }, id: \.id) { card in
                    Button { shown = card } label: { row(card) }
                        .buttonStyle(.plain)
                }
            }
            // As in the concept: a plain list with dividers, no card behind it.
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(String.localizedFormat("Рядом · %@".localized, "\(people.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово".localized) { dismiss() }
                }
            }
            .shumSheet(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } })) {
                if let card = shown {
                    ShumContactConfirmation(card: card, isExistingContact: contacts.contains(card.id)) {
                        write(card)
                    }
                }
            }
        }
    }

    private func row(_ card: ShumContactCard) -> some View {
        HStack(spacing: 12) {
            ShumAvatar(name: card.name, size: 40, imageData: avatar(card))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                let details = [
                    distance(card).map { String(format: "distanceMetersFormat".localized, $0) },
                    writers.contains(card.id) ? "пишет".localized : nil,
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if contacts.contains(card.id) {
                Text("в контактах".localized).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// What the open chat is, in three points.
private struct ShumPublicChatAbout: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    point("dot.radiowaves.left.and.right", "Видят все, кто рядом".localized,
                          "Сообщения получают все, у кого поблизости открыт Shum и включён Bluetooth. Телефоны передают их друг другу, поэтому чат охватывает всех вокруг. Кто ушёл далеко, новых сообщений уже не увидит.".localized)
                    point("wifi.slash", "Работает без интернета".localized,
                          "Сообщения идут по Bluetooth с телефона на телефон. Сервера нет, поэтому чат работает даже там, где нет сети.".localized)
                    point("lock.open", "Не для секретов".localized,
                          "Общий чат открыт всем вокруг. Личное лучше написать человеку в обычный чат: там сообщения видите только вы двое.".localized)
                }
                .padding(24)
            }
            .navigationTitle("Общий чат".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово".localized) { dismiss() }
                }
            }
        }
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
