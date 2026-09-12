import BitFoundation
import SwiftUI

/// A person can belong to several folders, but occupies one row in each folder.
enum ShumChatFolder: String, CaseIterable, Identifiable {
    case all = "Все", unread = "Непрочитанное", invitations = "Приглашения"
    case nearby = "Рядом", encounters = "Виделись", saved = "Сохранённые"
    var id: String { rawValue }
}

struct ShumDirectoryEntry: Identifiable {
    let peer: SpotchatPeer
    var card: SpotchatContactCard?
    var hasChat = false
    var isInvitation = false
    var isNearby = false
    var isSaved = false
    var lastSeen: Date?
    var unread = 0
    var id: PeerID { peer.id }

    func belongs(to folder: ShumChatFolder) -> Bool {
        switch folder {
        case .all: true
        case .unread: unread > 0 || isInvitation
        case .invitations: isInvitation
        case .nearby: isNearby
        case .encounters: lastSeen != nil
        case .saved: isSaved
        }
    }
}

extension SpotchatRuntime {
    var directoryEntries: [ShumDirectoryEntry] {
        ShumChatDirectory.entries(chats: chatPeers, peers: peers, permanent: permanent,
                                  isNearby: isNearby, unreadCount: unreadCount)
    }
}

@MainActor
enum ShumChatDirectory {
    static func entries(chats: [SpotchatPeer], peers: [SpotchatPeer], permanent: SpotchatMessageStore?,
                        isNearby: (PeerID) -> Bool, unreadCount: (PeerID) -> Int) -> [ShumDirectoryEntry] {
        var rows: [PeerID: ShumDirectoryEntry] = [:]
        var order: [PeerID] = []
        func include(_ peer: SpotchatPeer, card: SpotchatContactCard? = nil,
                     update: (inout ShumDirectoryEntry) -> Void) {
            let verifiedCard = card ?? permanent?.card(for: peer.id)
            let canonical = verifiedCard.map {
                SpotchatPeer(id: $0.peerID, name: $0.name, lastConnected: peer.lastConnected)
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
            include(SpotchatPeer(id: card.peerID, name: card.name, lastConnected: .distantPast), card: card) {
                $0.isInvitation = true
            }
        }
        for peer in peers { include(peer) { $0.isNearby = isNearby(peer.id) } }
        for encounter in permanent?.encounterHistory ?? [] {
            include(SpotchatPeer(id: encounter.card.peerID, name: encounter.card.name, lastConnected: encounter.lastSeen), card: encounter.card) {
                $0.lastSeen = encounter.lastSeen
            }
        }
        for profile in permanent?.savedProfiles ?? [] {
            include(SpotchatPeer(id: profile.card.peerID, name: profile.card.name, lastConnected: profile.savedAt), card: profile.card) {
                $0.isSaved = true
            }
        }
        // Retain contacts whose local conversation was deleted, without recreating it.
        for contact in permanent?.state.contacts ?? [] {
            include(SpotchatPeer(id: contact.card.peerID, name: contact.card.name, lastConnected: contact.addedAt), card: contact.card) { _ in }
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
    @Namespace private var indicator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ShumChatFolder.allCases) { folder in
                        let active = selection == folder
                        let count = entries.filter { $0.belongs(to: folder) }.count
                        Button {
                            withAnimation(.snappy(duration: 0.24)) { selection = folder }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            HStack(spacing: 5) {
                                Text(folder.rawValue).font(.subheadline.weight(.semibold))
                                Text(String(count))
                                    .font(.caption2.weight(.semibold)).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14), in: Capsule())
                            }
                            .foregroundStyle(active ? Color.primary : .secondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background {
                                if active {
                                    Capsule().fill(Color.primary.opacity(0.10)).frame(height: 36)
                                        .matchedGeometryEffect(id: "folder", in: indicator)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(folder)
                        .accessibilityLabel("\(folder.rawValue), \(count)")
                        .accessibilityAddTraits(active ? [.isSelected] : [])
                        .accessibilityIdentifier("shum.folder.\(folder)")
                    }
                }
                .padding(.horizontal, 4)
            }
            .clipShape(Capsule())
            .modifier(ShumFolderGlass())
            .onChange(of: selection) { value in
                withAnimation(.snappy(duration: 0.24)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground), ignoresSafeAreaEdges: [])
    }
}

private struct ShumFolderGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}

/// An original-color image avoids the system's white template tint on swipe buttons.
struct ShumSwipeLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: (UIImage(systemName: systemImage) ?? UIImage()).withTintColor(.black, renderingMode: .alwaysOriginal))
                .renderingMode(.original)
        }
    }
}
