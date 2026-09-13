#if os(iOS)
import SwiftUI

struct ShumContactsUI: View {
    @ObservedObject var runtime: SpotchatRuntime
    let open: (SpotchatUIRoute) -> Void

    private var contacts: [SpotchatContact] {
        guard let permanent = runtime.permanent else { return [] }
        return permanent.state.contacts
            .filter { !permanent.isBlocked($0.card) }
            .sorted {
                $0.card.name.localizedStandardCompare($1.card.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            if contacts.isEmpty {
                VStack(spacing: 8) {
                    Text("Нет контактов")
                        .font(.headline)
                    Text("Добавленные контакты появятся здесь.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(contacts) { contact in
                    let peer = SpotchatPeer(
                        id: contact.card.peerID,
                        name: contact.card.name,
                        lastConnected: contact.addedAt
                    )
                    Button { open(.conversation(peer)) } label: {
                        HStack(spacing: 12) {
                            ShumProfileAvatar(
                                size: 42,
                                imageData: runtime.profile(for: peer.id)?.avatar ?? contact.avatar
                            )
                            Text(runtime.displayName(peer))
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.peopleListBackground)
                    .accessibilityHint("Открыть чат")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.peopleListBackground)
        .navigationTitle("Контакты")
        .navigationBarTitleDisplayMode(.large)
    }
}
#endif
