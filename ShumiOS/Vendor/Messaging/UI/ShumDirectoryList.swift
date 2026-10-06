#if os(iOS)
import SwiftUI
import UIKit
import BitFoundation

private struct ShumDirectoryRowID: Hashable {
    let folder: ShumChatFolder
    let peer: PeerID
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
    @State private var pendingPin: PeerID?
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
            UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.48, dampingFraction: 0.84),
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
            hidesPersistentSurfaceAfterSwipe: false,
            onSwipeSettled: { finishPendingPin(entry) }
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
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.card != nil {
                Button { pinAfterSwipe(entry) } label: {
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
    /// A swipe button only remembers the chat. List cannot animate moving a
    /// row while its swipe is still closing, so the order changes once the
    /// row is back in place.
    private func pinAfterSwipe(_ entry: ShumDirectoryEntry) {
        guard entry.card != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        pendingPin = entry.id
        // The row may scroll away before it reports the end of its swipe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finishPendingPin(entry) }
    }
    private func finishPendingPin(_ entry: ShumDirectoryEntry) {
        guard pendingPin == entry.id else { return }
        pendingPin = nil
        togglePinned(entry, feedback: false)
    }
    /// The order changes at once and List animates the move.
    private func togglePinned(_ entry: ShumDirectoryEntry, feedback: Bool = true) {
        guard let card = entry.card else { return }
        if feedback { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        do {
            try withAnimation {
                _ = try runtime.permanent?.togglePinned(card, in: folder.pinKey)
            }
        } catch {
            runtime.error = error.localizedDescription
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
                .overlay(alignment: .bottomTrailing) {
                    if typing || runtime.isInChat(entry.peer.id) {
                        ShumPresenceBadge(seed: entry.peer.id.id)
                            .offset(x: 2, y: 1)
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
                    // Typing is shown only by the pulsing pixels on the avatar.
                    if let last, last.outgoing, !entry.isInvitation {
                        ShumDeliveryReceipt(status: last.status)
                            .font(.system(size: 11, weight: .medium))
                            .accessibilityLabel(ShumDeliveryReceipt.description(for: last.status))
                    }
                    let preview = invitationSummary ?? last?.text ?? "Начать чат".localized
                    Text(preview)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(typing ? "печатает".localized : preview)
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
#endif
