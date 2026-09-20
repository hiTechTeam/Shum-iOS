import BitFoundation
import SwiftUI
import UIKit

/// A person can belong to several folders, but occupies one row in each folder.
enum ShumChatFolder: String, CaseIterable, Hashable, Identifiable {
    case all = "Все", unread = "Непрочитанное", invitations = "Приглашения"
    case nearby = "Рядом", encounters = "Виделись"
    var id: String { rawValue }
    var pinKey: String {
        switch self {
        case .all: "all"
        case .unread: "unread"
        case .invitations: "invitations"
        case .nearby: "nearby"
        case .encounters: "encounters"
        }
    }
    static let visibleFolders: [ShumChatFolder] = [
        .all, .invitations, .nearby, .unread
    ]
}

struct ShumDirectoryEntry: Identifiable {
    let peer: ShumPeer
    var card: ShumContactCard?
    var hasChat = false
    var isInvitation = false
    var invitationPhase: ShumInvitationPhase?
    var invitationAwaitingResponse = false
    var isNearby = false
    var lastSeen: Date?
    var unread = 0
    var id: PeerID { peer.id }

    func belongs(to folder: ShumChatFolder) -> Bool {
        switch folder {
        case .all: return hasChat || isInvitation || isNearby
        case .unread: return unread > 0 || invitationAwaitingResponse
        case .invitations: return isInvitation
        case .nearby: return isNearby
        case .encounters:
            guard let lastSeen else { return false }
            return lastSeen >= Date().addingTimeInterval(-24 * 60 * 60)
        }
    }
}

extension ShumRuntime {
    var directoryEntries: [ShumDirectoryEntry] {
        ShumChatDirectory.entries(chats: chatPeers, peers: peers, permanent: permanent,
                                  isNearby: isNearby, unreadCount: unreadCount)
    }
}

@MainActor
enum ShumChatDirectory {
    static func entries(chats: [ShumPeer], peers: [ShumPeer], permanent: ShumMessageStore?,
                        isNearby: (PeerID) -> Bool, unreadCount: (PeerID) -> Int) -> [ShumDirectoryEntry] {
        var rows: [PeerID: ShumDirectoryEntry] = [:]
        var order: [PeerID] = []
        func include(_ peer: ShumPeer, card: ShumContactCard? = nil,
                     update: (inout ShumDirectoryEntry) -> Void) {
            let verifiedCard = card ?? permanent?.card(for: peer.id)
            let canonical = verifiedCard.map {
                ShumPeer(id: $0.peerID, name: $0.name, lastConnected: peer.lastConnected)
            } ?? peer
            guard verifiedCard.map({ permanent?.isBlocked($0) != true }) ?? true else { return }
            if rows[canonical.id] == nil {
                order.append(canonical.id)
                rows[canonical.id] = ShumDirectoryEntry(peer: canonical, card: verifiedCard)
            }
            if let verifiedCard { rows[canonical.id]?.card = verifiedCard }
            update(&rows[canonical.id]!)
        }
        for peer in chats { include(peer) { $0.hasChat = true } }
        for card in permanent?.state.requests ?? [] {
            include(ShumPeer(id: card.peerID, name: card.name, lastConnected: .distantPast), card: card) {
                $0.isInvitation = true
                $0.invitationPhase = permanent?.invitationPhase(for: card)
                $0.invitationAwaitingResponse = permanent?.invitationPhase(for: card) == .incomingPending
            }
        }
        for peer in peers {
            if let permanent {
                // Transport peers use a short, connection-level identifier.
                // After a disconnect that identifier remains in the radio cache
                // briefly, while its verified card is removed immediately. Do
                // not turn that stale session into a second directory person.
                guard let card = permanent.card(for: peer.id) else { continue }
                include(peer, card: card) { $0.isNearby = isNearby(peer.id) }
            } else {
                include(peer) { $0.isNearby = isNearby(peer.id) }
            }
        }
        for encounter in permanent?.encounterHistory ?? [] {
            include(ShumPeer(id: encounter.card.peerID, name: encounter.card.name, lastConnected: encounter.lastSeen), card: encounter.card) {
                $0.lastSeen = encounter.lastSeen
            }
        }
        // Retain contacts whose local conversation was deleted, without recreating it.
        for contact in permanent?.state.contacts ?? [] {
            include(ShumPeer(id: contact.card.peerID, name: contact.card.name, lastConnected: contact.addedAt), card: contact.card) { _ in }
        }
        return order.compactMap { id in
            guard var row = rows[id] else { return nil }
            row.isNearby = row.isNearby || isNearby(id)
            row.unread = unreadCount(id)
            return row
        }
    }
}

struct ShumChatFolderBar: View {
    @Binding var selection: ShumChatFolder
    let entries: [ShumDirectoryEntry]
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 44

    var body: some View {
        ShumNativeFolderPicker(
            selection: $selection,
            counts: ShumChatFolder.visibleFolders.map { folder in entries.filter { $0.belongs(to: folder) }.count }
        )
        .frame(height: max(44, height))
    }
}

/// One bounded horizontal viewport; the surrounding List owns vertical scrolling.
private struct ShumNativeFolderPicker: UIViewRepresentable {
    @Binding var selection: ShumChatFolder
    let counts: [Int]
    @ObservedObject private var appearance = ShumAppearanceStore.shared

    func makeUIView(context: Context) -> FolderViewport { FolderViewport() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FolderViewport, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? 44)
    }

    func updateUIView(_ view: FolderViewport, context: Context) {
        let folders = ShumChatFolder.visibleFolders
        view.changed = { index in
            guard folders.indices.contains(index) else { return }
            selection = folders[index]
        }
        view.update(titles: zip(folders, counts).map { "\($0.0.rawValue)  \($0.1)" },
                    selected: folders.firstIndex(of: selection) ?? 0,
                    accentColor: appearance.accentUIColor)
    }

    final class FolderViewport: UIView {
        private let glassView: UIVisualEffectView = {
            if #available(iOS 26.0, *) {
                return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            } else {
                return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            }
        }()
        private let scrollView = FolderScrollView()
        private let selectionView = UIView()
        private var buttons: [UIButton] = []
        private var selected = -1
        private var needsSelectionReveal = false
        var changed: ((Int) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = .clear
            layer.cornerCurve = .continuous
            if #unavailable(iOS 26.0) {
                layer.borderWidth = 0.5
                layer.borderColor = UIColor.separator.withAlphaComponent(0.32).cgColor
            }
            glassView.isUserInteractionEnabled = false
            addSubview(glassView)
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceHorizontal = true
            scrollView.isDirectionalLockEnabled = true
            scrollView.canCancelContentTouches = true
            scrollView.delaysContentTouches = false
            scrollView.scrollsToTop = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.accessibilityIdentifier = "shum.chatFolders"
            addSubview(scrollView)
            selectionView.backgroundColor = ShumAppearanceStore.shared.accentUIColor.withAlphaComponent(0.2)
            selectionView.isUserInteractionEnabled = false
            selectionView.layer.cornerCurve = .continuous
            scrollView.addSubview(selectionView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(titles: [String], selected: Int, accentColor: UIColor) {
            selectionView.backgroundColor = accentColor.withAlphaComponent(0.2)
            if buttons.count != titles.count {
                buttons.forEach { $0.removeFromSuperview() }
                buttons = titles.indices.map { index in
                    let button = UIButton(type: .system)
                    button.tag = index
                    button.setTitleColor(.label, for: .normal)
                    button.addTarget(self, action: #selector(selectedFolder(_:)), for: .touchUpInside)
                    scrollView.addSubview(button)
                    return button
                }
            }
            for (button, title) in zip(buttons, titles) {
                button.setTitle(title, for: .normal)
            }
            if self.selected != selected {
                self.selected = selected
                needsSelectionReveal = true
            }
            updateAccessibility()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The viewport never takes its width from the longer row of buttons.
            glassView.frame = bounds
            scrollView.frame = bounds
            layer.cornerRadius = bounds.height / 2
            glassView.layer.cornerCurve = .continuous
            glassView.layer.cornerRadius = bounds.height / 2
            glassView.clipsToBounds = true
            let font = UIFont.preferredFont(forTextStyle: .subheadline)
            var x: CGFloat = 3
            for button in buttons {
                button.titleLabel?.font = font
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                let title = button.title(for: .normal) ?? ""
                let width = max(44, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 28)
                button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
                x += width
            }
            scrollView.contentSize = CGSize(width: max(bounds.width, x + 3), height: bounds.height)
            updateSelectionFrame()
            if needsSelectionReveal, bounds.width > 0 {
                needsSelectionReveal = false
                revealSelection(animated: false)
            }
        }

        private func updateSelectionFrame() {
            guard buttons.indices.contains(selected) else { return }
            selectionView.frame = buttons[selected].frame.insetBy(dx: 0, dy: 3)
            selectionView.layer.cornerRadius = selectionView.bounds.height / 2
        }

        private func updateAccessibility() {
            for (index, button) in buttons.enumerated() {
                button.accessibilityTraits = index == selected ? [.button, .selected] : [.button]
            }
        }

        private func revealSelection(animated: Bool) {
            guard buttons.indices.contains(selected) else { return }
            scrollView.scrollRectToVisible(buttons[selected].frame, animated: animated)
        }

        @objc private func selectedFolder(_ button: UIButton) {
            guard selected != button.tag else { return }
            selected = button.tag
            updateAccessibility()
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.updateSelectionFrame()
            }
            UISelectionFeedbackGenerator().selectionChanged()
            changed?(selected)
            revealSelection(animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    final class FolderScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool { true }
    }
}
