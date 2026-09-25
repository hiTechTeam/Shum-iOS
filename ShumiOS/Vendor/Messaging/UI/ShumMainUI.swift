#if os(iOS)
import SwiftUI
import UIKit
import BitFoundation

// Current Shum chat list, adapted to Shum's navigation and palette.
enum ShumUIRoute: Hashable {
    case conversation(ShumPeer), newChat, requests, ownQR

    var containsMessages: Bool {
        if case .conversation = self { return true }
        return false
    }
}

private struct ShumDirectoryRowID: Hashable {
    let folder: ShumChatFolder
    let peer: PeerID
}

struct ShumDestinationUI: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: ShumRuntime
    let route: ShumUIRoute
    let open: (ShumUIRoute) -> Void
    var body: some View {
        Group {
            switch route {
            case .conversation(let peer):
                ShumConversationView(runtime: runtime, peer: peer)
            case .newChat: ShumContactsView(runtime: runtime) { open(.conversation($0)) }
            case .requests: ShumContactRequestsView(runtime: runtime) { open(.conversation($0)) }
            case .ownQR:
                if let card = runtime.permanent?.ownCard {
                    ShumQRView(
                        card: card,
                        resolve: { locator, completion in
                            runtime.resolveContact(locator, completion: completion)
                        }
                    ) { scannedCard in
                        coordinator.invitation = scannedCard
                    }
                }
            }
        }
    }
}

struct ShumChatsUI: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: ShumRuntime
    let open: (ShumUIRoute) -> Void
    @State private var folder: ShumChatFolder = .all
    @State private var showsNewMessage = false

    private var entries: [ShumDirectoryEntry] { runtime.directoryEntries }
    private var visible: [ShumDirectoryEntry] {
        let matching = entries.filter { $0.belongs(to: folder) }
        let pinnedIDs = runtime.permanent?.pinnedCardIDs(in: folder.pinKey) ?? []
        let pinnedRanks = Dictionary(
            uniqueKeysWithValues: pinnedIDs.enumerated().map { ($1, $0) }
        )
        return matching.enumerated().sorted { lhs, rhs in
            let lhsRank = lhs.element.card.flatMap { pinnedRanks[$0.id] }
            let rhsRank = rhs.element.card.flatMap { pinnedRanks[$0.id] }
            switch (lhsRank, rhsRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func isPinned(_ entry: ShumDirectoryEntry) -> Bool {
        guard let card = entry.card else { return false }
        return runtime.permanent?.isPinned(card, in: folder.pinKey) == true
    }

    var body: some View {
        ShumDirectoryList(
            runtime: runtime, folder: folder, entries: visible, open: open,
            pinsHeader: true
        ) {
            ShumChatFolderBar(selection: $folder, entries: entries)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
        } empty: {
            emptyState
        }
        .refreshable { runtime.tick() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text(runtime.internetConnected
                     ? "Сквозное шифрование · Nostr подключён".localized
                     : "Сквозное шифрование · Ожидаем сеть".localized)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle("Чаты".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsNewMessage = true
                } label: {
                    newMessageIcon
                }
                .tint(.primary)
                .accessibilityLabel("Написать сообщение".localized)
                .accessibilityIdentifier("shum.newMessage")
            }
        }
        .sheet(isPresented: $showsNewMessage) {
            ShumNewMessageSheet(runtime: runtime) { peer in
                guard showsNewMessage else { return }
                showsNewMessage = false
                open(.conversation(peer))
            }
            .shumAllowsScreenshots()
        }
        .shumOnChange(of: folder) { _, folder in
            if folder == .encounters { runtime.permanent?.markEncountersViewed() }
        }
        .shumHiddenFromSystemCapture(true)
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewPeople") { folder = .nearby }
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-ShumPreviewFolder"),
               arguments.indices.contains(index + 1),
               let previewFolder = ShumChatFolder(rawValue: arguments[index + 1]) {
                folder = previewFolder
            }
        }
        #endif
    }

    @ViewBuilder
    private var newMessageIcon: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: "square.and.pencil")
                .offset(y: -1)
        } else {
            Image(systemName: "square.and.pencil")
        }
    }

    private var emptyState: some View {
        ShumChatEmptyState(folder: folder, visibilityEnabled: coordinator.isScaning) {
            switch folder {
            case .all, .invitations:
                open(.newChat)
            case .unread:
                withAnimation(.easeInOut(duration: 0.2)) { folder = .all }
            case .nearby, .encounters:
                break
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(420, UIScreen.main.bounds.height * 0.54))
        .padding(.horizontal, 24)
    }
}

private struct ShumChatEmptyState: View {
    let folder: ShumChatFolder
    let visibilityEnabled: Bool
    let action: () -> Void

    private var accent: Color { .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            ShumPixelEmptyIcon(kind: iconKind)
                .foregroundStyle(.primary)
                .frame(width: 88, height: 68)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            if let status {
                Text(status)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: 330)
        .accessibilityElement(children: .contain)
    }

    private var iconKind: ShumPixelEmptyIcon.Kind {
        switch folder {
        case .all: .chats
        case .nearby: .nearby
        case .unread: .read
        case .invitations: .invitation
        case .encounters: .encounters
        }
    }

    private var title: String {
        switch folder {
        case .all: "Пока тихо".localized
        case .nearby: visibilityEnabled ? "Никого рядом".localized : "Видимость выключена".localized
        case .unread: "Всё прочитано".localized
        case .invitations: "Нет приглашений".localized
        case .encounters: "Пока не встречались".localized
        }
    }

    private var message: String {
        switch folder {
        case .all: "Новые разговоры появятся здесь.".localized
        case .nearby:
            visibilityEnabled
                ? "Видимость по Bluetooth работает автоматически.".localized
                : "Включите видимость в профиле, чтобы находить людей рядом через Bluetooth.".localized
        case .unread: "Новых сообщений пока нет.".localized
        case .invitations: "Новые приглашения появятся здесь.".localized
        case .encounters: "Встречи поблизости сохранятся здесь.".localized
        }
    }

    private var actionTitle: String? {
        switch folder {
        case .all, .invitations: "Добавить контакт".localized
        case .unread: "Все чаты".localized
        case .nearby, .encounters: nil
        }
    }

    private var status: String? {
        switch folder {
        case .encounters: "Все встречи за 24 часа".localized
        default: nil
        }
    }
}

/// Small bitmap drawings keep the empty states in Shum's pixel language without
/// introducing a second illustration palette.
struct ShumPixelEmptyIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    enum Kind { case chats, contacts, nearby, read, invitation, encounters, blocked }
    let kind: Kind

    var body: some View {
        PixelDrawing(pixels: pixels).fill(colorScheme == .dark ? Color.white : Color.black)
    }

    private struct PixelDrawing: Shape {
        let pixels: [Pixel]

        func path(in rect: CGRect) -> Path {
            let unit: CGFloat = 4
            let drawingSize = CGSize(width: 22 * unit, height: 17 * unit)
            let origin = CGPoint(
                x: rect.midX - drawingSize.width / 2,
                y: rect.midY - drawingSize.height / 2
            )
            var path = Path()
            for pixel in Set(pixels) {
                path.addRect(CGRect(
                    x: origin.x + CGFloat(pixel.x) * unit,
                    y: origin.y + CGFloat(pixel.y) * unit,
                    width: unit,
                    height: unit
                ))
            }
            return path
        }
    }

    private var pixels: [Pixel] {
        switch kind {
        case .chats:
            outline(x: 1, y: 2, width: 11, height: 8, tail: .left)
            + outline(x: 11, y: 7, width: 10, height: 7, tail: .right)
            + [Pixel(4, 6), Pixel(6, 6), Pixel(8, 6), Pixel(14, 10), Pixel(16, 10), Pixel(18, 10)]
        case .contacts:
            person(x: 3, y: 5) + person(x: 11, y: 5)
        case .nearby:
            person(x: 1, y: 5) + person(x: 16, y: 5)
            + [Pixel(10, 7), Pixel(12, 7), Pixel(13, 6), Pixel(13, 8), Pixel(14, 5), Pixel(14, 9)]
        case .read:
            line(from: Pixel(5, 2), to: Pixel(5, 14))
            + line(from: Pixel(6, 2), to: Pixel(16, 2))
            + line(from: Pixel(6, 9), to: Pixel(14, 9))
            + line(from: Pixel(16, 2), to: Pixel(16, 6))
            + [Pixel(12, 6), Pixel(13, 7), Pixel(14, 6), Pixel(15, 5), Pixel(16, 4)]
        case .invitation:
            person(x: 4, y: 3)
            + line(from: Pixel(15, 8), to: Pixel(15, 14))
            + line(from: Pixel(12, 11), to: Pixel(18, 11))
        case .encounters:
            person(x: 1, y: 5) + person(x: 16, y: 5)
            + [Pixel(10, 8), Pixel(12, 8), Pixel(11, 9), Pixel(10, 10), Pixel(12, 10)]
        case .blocked:
            person(x: 1, y: 5)
            + outline(x: 13, y: 7, width: 8, height: 7, tail: nil)
            + line(from: Pixel(15, 6), to: Pixel(15, 5))
            + line(from: Pixel(16, 4), to: Pixel(18, 4))
            + line(from: Pixel(19, 5), to: Pixel(19, 6))
            + [Pixel(16, 10), Pixel(17, 10), Pixel(17, 11)]
        }
    }

    private func person(x: Int, y: Int) -> [Pixel] {
        outline(x: x + 2, y: y, width: 4, height: 4, tail: nil)
        + line(from: Pixel(x + 1, y + 5), to: Pixel(x + 6, y + 5))
        + line(from: Pixel(x, y + 6), to: Pixel(x, y + 9))
        + line(from: Pixel(x + 7, y + 6), to: Pixel(x + 7, y + 9))
        + line(from: Pixel(x, y + 9), to: Pixel(x + 7, y + 9))
    }

    private func heart(x: Int, y: Int) -> [Pixel] {
        [Pixel(x + 1, y), Pixel(x + 2, y), Pixel(x + 4, y), Pixel(x + 5, y),
         Pixel(x, y + 1), Pixel(x + 1, y + 1), Pixel(x + 2, y + 1), Pixel(x + 3, y + 1), Pixel(x + 4, y + 1), Pixel(x + 5, y + 1), Pixel(x + 6, y + 1),
         Pixel(x, y + 2), Pixel(x + 1, y + 2), Pixel(x + 2, y + 2), Pixel(x + 3, y + 2), Pixel(x + 4, y + 2), Pixel(x + 5, y + 2), Pixel(x + 6, y + 2),
         Pixel(x + 1, y + 3), Pixel(x + 2, y + 3), Pixel(x + 3, y + 3), Pixel(x + 4, y + 3), Pixel(x + 5, y + 3),
         Pixel(x + 2, y + 4), Pixel(x + 3, y + 4), Pixel(x + 4, y + 4), Pixel(x + 3, y + 5)]
    }

    private enum Tail { case left, right }

    private func outline(x: Int, y: Int, width: Int, height: Int, tail: Tail?) -> [Pixel] {
        var result = line(from: Pixel(x + 1, y), to: Pixel(x + width - 2, y))
        result += line(from: Pixel(x, y + 1), to: Pixel(x, y + height - 2))
        result += line(from: Pixel(x + width - 1, y + 1), to: Pixel(x + width - 1, y + height - 2))
        result += line(from: Pixel(x + 1, y + height - 1), to: Pixel(x + width - 2, y + height - 1))
        if tail == .left { result += [Pixel(x + 2, y + height), Pixel(x + 2, y + height + 1), Pixel(x + 3, y + height)] }
        if tail == .right { result += [Pixel(x + width - 3, y + height), Pixel(x + width - 3, y + height + 1), Pixel(x + width - 4, y + height)] }
        return result
    }

    private func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        if start.x == end.x {
            return (min(start.y, end.y)...max(start.y, end.y)).map { Pixel(start.x, $0) }
        }
        return (min(start.x, end.x)...max(start.x, end.x)).map { Pixel($0, start.y) }
    }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}

/// Chat directory rows, swipe actions and confirmation presentation.
struct ShumDirectoryList<Header: View, Empty: View>: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let folder: ShumChatFolder
    let entries: [ShumDirectoryEntry]
    let open: (ShumUIRoute) -> Void
    var pinsHeader = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let empty: () -> Empty
    @State private var selectedPeer: ShumPeer?
    @State private var pendingAction: DirectoryConfirmation?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var elevatedPeerIDs: Set<PeerID> = []
    @State private var pinTransitionPeerIDs: Set<PeerID> = []
    @State private var directoryScrollOffset: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var folderHeight: CGFloat = 44

    var body: some View {
        list
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                open(.conversation(peer))
            }
            .presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
        .alert(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("Отмена".localized, role: .cancel) { pendingAction = nil }
            Button(action.buttonTitle, role: .destructive) { confirm(action); pendingAction = nil }
        } message: { action in Text(action.message) }
    }

    private var list: some View {
        List {
            if pinsHeader {
                Color.clear
                    .frame(height: max(44, folderHeight) + 14)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            } else {
                header()
            }
            rows
        }
        .listStyle(.plain)
        .accessibilityIdentifier("shum.chatDirectory")
        .environment(\.defaultMinListRowHeight, 0)
        .modifier(ShumDirectoryScrollInsets())
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .modifier(ShumDirectoryScrollTracking(enabled: pinsHeader, offset: $directoryScrollOffset))
        .overlay(alignment: .top) {
            if pinsHeader {
                header()
                    .offset(y: max(0, -directoryScrollOffset))
                    .transaction { $0.animation = nil }
            }
        }
        .animation(
            .spring(response: 0.48, dampingFraction: 0.84),
            value: entries.map(\.id)
        )
    }

    @ViewBuilder private var rows: some View {
        if entries.isEmpty {
            empty()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                directoryRow(entry, isLast: index == entries.count - 1)
                    .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                    .id(ShumDirectoryRowID(folder: folder, peer: entry.id))
            }
        }
    }

    private func directoryRow(_ entry: ShumDirectoryEntry, isLast: Bool) -> some View {
        let pinned = isPinned(entry)
        return NativeSwipeInteractionRow(
            persistentSurfaceColor: pinned
                ? palette.pinnedRowSurface
                : nil,
            hidesPersistentSurfaceAfterSwipe: false
        ) {
            ShumRowPressButton(action: { activate(entry) }) {
                ShumDirectoryRow(
                    runtime: runtime,
                    entry: entry,
                    isPinned: pinned,
                    showsNearbyIndicator: folder != .nearby
                )
            }
            .contextMenu { menu(entry) } preview: {
                ShumDirectoryContextPreview(
                    runtime: runtime,
                    entry: entry,
                    isPinned: pinned,
                    showsNearbyIndicator: folder != .nearby
                )
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(ShumThemeCanvas())
        .listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
        .listRowSeparatorTint(Color.secondary.opacity(0.24))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 86 }
        .zIndex(elevatedPeerIDs.contains(entry.id) ? 1_000 : (pinned ? 1 : 0))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.card != nil {
                Button { togglePinned(entry) } label: {
                    Label(pinned ? "Открепить".localized : "Закрепить".localized, systemImage: pinned ? "pin.slash" : "pin.fill")
                }.tint(Color(uiColor: .systemGray))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            trailingActions(entry)
        }
    }

    @ViewBuilder private func trailingActions(_ entry: ShumDirectoryEntry) -> some View {
        if let card = entry.card {
            if entry.isInvitation && entry.invitationPhase == .incomingPending {
                Button { pendingAction = .decline(card) } label: {
                    Label("Отклонить".localized, systemImage: "xmark")
                }
                .tint(.red)

                Button { requestBlock(entry, afterSwipe: true) } label: {
                    Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                }
                .tint(.red)
            } else {
                Button { requestBlock(entry, afterSwipe: true) } label: {
                    Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                }
                .tint(.red)

                if canClear(entry) {
                    Button { pendingAction = .clear(card) } label: {
                        Label("Очистить".localized, systemImage: "trash")
                    }
                    .tint(Color(uiColor: .systemGray))
                }
            }
        }
    }

    @ViewBuilder private func menu(_ entry: ShumDirectoryEntry) -> some View {
        if let card = entry.card, !runtime.isContact(entry.peer.id) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                _ = runtime.addContact(card, source: "chat-menu")
            } label: {
                Label("Добавить в контакты".localized, systemImage: "person.badge.plus")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)

            Divider()
        }
        Button { selectedPeer = entry.peer } label: {
            Label("Посмотреть профиль".localized, systemImage: "person.crop.circle").foregroundStyle(.primary)
        }.tint(.primary)
        Button { activate(entry) } label: {
            Label(entry.isInvitation ? "Открыть приглашение".localized : "Написать".localized, systemImage: "paperplane").foregroundStyle(.primary)
        }.tint(.primary)
        if let card = entry.card {
            let pinned = isPinned(entry)
            Button { togglePinned(entry) } label: {
                Label(pinned ? "Открепить".localized : "Закрепить".localized, systemImage: pinned ? "pin.slash" : "pin.fill").foregroundStyle(.primary)
            }.tint(.primary)
            if entry.isInvitation, entry.invitationPhase == .incomingPending {
                Button(role: .destructive) { pendingAction = .decline(card) } label: {
                    Label("Отклонить приглашение".localized, systemImage: "xmark").foregroundStyle(.red)
                }
                .tint(.red)
            } else if canClear(entry) {
                Button(role: .destructive) { pendingAction = .clear(card) } label: {
                    Label("Очистить".localized, systemImage: "trash").foregroundStyle(.red)
                }
                .tint(.red)
            }
            Divider()
            Button(role: .destructive) { requestBlock(entry, afterSwipe: false) } label: {
                Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.red)
            }.tint(.red)
        }
    }

    private func activate(_ entry: ShumDirectoryEntry) {
        open(.conversation(entry.peer))
    }
    private func togglePinned(_ entry: ShumDirectoryEntry) {
        guard let card = entry.card else { return }
        guard pinTransitionPeerIDs.insert(entry.id).inserted else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let peerID = entry.id
        let pinKey = folder.pinKey
        Task { @MainActor in
            // Let the system swipe/context menu close before the row changes position.
            try? await Task.sleep(for: .milliseconds(300))
            elevatedPeerIDs.insert(peerID)

            // Commit the elevated stacking order before starting the list move.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(35))

            do {
                try withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                    _ = try runtime.permanent?.togglePinned(card, in: pinKey)
                }
            } catch {
                runtime.error = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(650))
            elevatedPeerIDs.remove(peerID)
            pinTransitionPeerIDs.remove(peerID)
        }
    }
    private func isPinned(_ entry: ShumDirectoryEntry) -> Bool {
        guard let card = entry.card else { return false }
        return runtime.permanent?.isPinned(card, in: folder.pinKey) == true
    }
    private func requestBlock(_ entry: ShumDirectoryEntry, afterSwipe: Bool) {
        guard let card = entry.card else { return }
        blockRequest = ShumProfileBlockRequest(peer: entry.peer, card: card, waitsForTransientUI: afterSwipe)
    }
    private func canClear(_ entry: ShumDirectoryEntry) -> Bool {
        entry.hasChat && !runtime.conversation(entry.peer.id).isEmpty
    }
    private func confirm(_ action: DirectoryConfirmation) {
        switch action {
        case .clear(let card):
            do { try runtime.permanent?.clearDirectoryEntry(card) }
            catch { runtime.error = error.localizedDescription }
        case .decline(let card):
            _ = runtime.declineInvitation(from: card.peerID)
        }
    }

}

private struct ShumDirectoryScrollInsets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentMargins(.top, 0, for: .scrollContent)
        } else {
            content
        }
    }
}

private struct ShumDirectoryScrollTracking: ViewModifier {
    let enabled: Bool
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { offset = value }
            }
        } else if enabled {
            content.background(ShumDirectoryLegacyScrollTracking(offset: $offset))
        } else {
            content
        }
    }
}

/// The same header geometry on iOS 16/17, before onScrollGeometryChange.
private struct ShumDirectoryLegacyScrollTracking: UIViewControllerRepresentable {
    @Binding var offset: CGFloat
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.changed = { value in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { offset = value }
        }
    }
    final class Controller: UIViewController {
        var changed: ((CGFloat) -> Void)?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            var owner: UIViewController = self
            while let parent = owner.parent, !(parent is UINavigationController) { owner = parent }
            guard let scroll = findScroll(in: owner.view), scroll !== scrollView else { return }
            scrollView = scroll
            observation = scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                let value = min(0, scroll.contentOffset.y + scroll.adjustedContentInset.top)
                DispatchQueue.main.async { [weak self] in self?.changed?(value) }
            }
        }
        private func findScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 100 { return scroll }
            return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
        }
    }
}

/// Keeps the preview laid out at exactly the same width as its source row,
/// then scales the finished row into the context-menu viewport. This makes
/// every trailing element travel with the avatar instead of relaying out and
/// jumping when the menu opens.
private struct ShumDirectoryContextPreview: View {
    @ObservedObject var runtime: ShumRuntime
    let entry: ShumDirectoryEntry
    let isPinned: Bool
    let showsNearbyIndicator: Bool

    private let sourceHeight: CGFloat = 78
    private var sourceWidth: CGFloat { UIScreen.main.bounds.width }
    private var previewWidth: CGFloat {
        min(sourceWidth, max(280, sourceWidth - 32))
    }
    private var previewScale: CGFloat {
        sourceWidth > 0 ? previewWidth / sourceWidth : 1
    }

    var body: some View {
        previewRow
            .frame(width: sourceWidth, height: sourceHeight)
            .clipShape(Capsule(style: .continuous))
            .containerShape(Capsule(style: .continuous))
            .scaleEffect(previewScale)
            .frame(
                width: previewWidth,
                height: sourceHeight * previewScale
            )
    }

    private var previewRow: some View {
        row
    }

    private var row: some View {
        ShumDirectoryRow(
            runtime: runtime,
            entry: entry,
            isPinned: isPinned,
            showsNearbyIndicator: showsNearbyIndicator
        )
    }
}

private enum DirectoryConfirmation {
    case clear(ShumContactCard), decline(ShumContactCard)
    var title: String {
        switch self {
        case .clear: "Очистить чат?".localized
        case .decline: "Отклонить приглашение?".localized
        }
    }
    var buttonTitle: String {
        switch self {
        case .clear: "Очистить".localized
        case .decline: "Отклонить".localized
        }
    }
    var message: String {
        switch self {
        case .clear:
            "История чата будет удалена только на этом устройстве. У собеседника сообщения сохранятся.".localized
        case .decline:
            "Запрос будет отклонён. Вы сможете принять его позднее в этом чате.".localized
        }
    }
}

struct ShumDirectoryRow: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let entry: ShumDirectoryEntry
    var isPinned = false
    var showsNearbyIndicator = true
    private var last: ShumMessage? { runtime.conversation(entry.peer.id).last }
    var body: some View {
        let typing = runtime.isTyping(entry.peer.id)
        HStack(spacing: 12) {
            ShumProfileAvatar(
                name: runtime.displayName(entry.peer),
                size: 58,
                imageData: runtime.profile(for: entry.peer.id)?.avatar
            )
                .mask {
                    Circle()
                        .fill(.white)
                        .overlay(alignment: .bottomTrailing) {
                            if runtime.isOnline(entry.peer.id) {
                                Circle()
                                    .frame(width: 14, height: 14)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                }
                .overlay(alignment: .bottomTrailing) {
                    if runtime.isOnline(entry.peer.id) {
                        Circle()
                            .fill(Color(uiColor: .systemGreen))
                            .frame(width: 10, height: 10)
                            .frame(width: 14, height: 14)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(runtime.displayName(entry.peer))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1)
                    if entry.isNearby && showsNearbyIndicator {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 4, height: 4)
                            Text("Рядом".localized)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Color.secondary)
                        }
                        .fixedSize()
                        .accessibilityLabel("Рядом".localized)
                    }
                    Spacer(minLength: 4)
                    if let last {
                        Text(last.date, style: .time).font(.system(size: 13)).foregroundStyle(Color.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if typing {
                        ShumChatListTypingIndicator()
                            .transition(.opacity)
                    } else {
                        Group {
                            if let last, last.outgoing, !entry.isInvitation {
                                ShumChatReceipt(status: last.status)
                            }
                            Text(invitationSummary ?? last?.text ?? "Начать чат".localized)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 4)
                    if entry.unread > 0 || entry.invitationAwaitingResponse {
                        Text(entry.unread > 99 ? "99+" : String(max(entry.unread, entry.invitationAwaitingResponse ? 1 : 0)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accentForeground)
                            .padding(.horizontal, 6).frame(minWidth: 21, minHeight: 21)
                            .background(Color.accentColor, in: Capsule())
                    } else if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 12, weight: .regular))
                            .rotationEffect(.degrees(40))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 21, height: 21)
                            .accessibilityLabel("Закреплён".localized)
                    }
                }
                .frame(minHeight: 21)
                .animation(.easeInOut(duration: 0.18), value: typing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.isInvitation ? "Открыть приглашение".localized : "Открыть чат".localized)
    }

    private var invitationSummary: String? {
        guard entry.isInvitation else { return nil }
        return entry.invitationPhase == .declinedLocally
            ? "Приглашение отклонено".localized
            : "Приглашение в чат".localized
    }
}

/// Mirrors Telegram's chat-list activity treatment: the message preview is
/// temporarily replaced by accent-colored text while the row keeps its layout.
private struct ShumChatListTypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.34, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Text("Печатает".localized)
            ForEach(0..<3, id: \.self) { index in
                Text(".")
                    .opacity(index <= phase ? 1 : 0.22)
            }
        }
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Печатает".localized)
    }
}

private struct ShumChatReceipt: View {
    let status: DeliveryStatus
    private var receiptDescription: String {
        switch status {
        case .read: "Прочитано".localized
        case .delivered: "Доставлено".localized
        case .sent: "Отправлено".localized
        case .failed: "Не доставлено".localized
        default: "Отправляется".localized
        }
    }
    var body: some View {
        Group {
            switch status {
            case .read:
                ShumDoubleCheck().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 10)
            case .delivered:
                ShumDoubleCheck().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 10)
            case .sent:
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            default:
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .accessibilityLabel(receiptDescription)
    }
}

#endif
