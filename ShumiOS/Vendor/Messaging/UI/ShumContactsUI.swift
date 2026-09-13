#if os(iOS)
import Contacts
import SwiftUI

struct ShumContactsUI: View {
    @ObservedObject var runtime: SpotchatRuntime
    let open: (SpotchatUIRoute) -> Void
    @State private var showPhoneBook = false
    @State private var share: SpotchatShareItem?

    private var service: SpotchatMessageStore? { runtime.permanent }

    private var contacts: [SpotchatContact] {
        guard let permanent = runtime.permanent else { return [] }
        return permanent.state.contacts
            .filter { !permanent.isBlocked($0.card) }
            .sorted {
                $0.card.name.localizedStandardCompare($1.card.name) == .orderedAscending
            }
    }

    private var sections: [ContactSection] {
        let grouped = Dictionary(grouping: contacts) { contact in
            let name = contact.card.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = name.first, first.isLetter else { return "#" }
            return String(first).uppercased(with: .current)
        }
        return grouped.map { ContactSection(title: $0.key, contacts: $0.value) }
            .sorted {
                if $0.title == "#" { return false }
                if $1.title == "#" { return true }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        List {
            inviteRow

            ForEach(sections) { section in
                Section {
                    ForEach(section.contacts) { contact in
                        contactRow(contact)
                    }
                } header: {
                    Text(section.title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.peopleListBackground)
        .navigationTitle("Контакты")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPhoneBook) {
            SpotchatPhoneBook { contact in
                showPhoneBook = false
                shareInvitation(for: contact)
            }
        }
        .sheet(item: $share) { item in
            SpotchatShareSheet(items: [item.text])
        }
    }

    private var inviteRow: some View {
        Button { showPhoneBook = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 42, height: 42)
                Text("Пригласить")
                    .font(.system(size: 17, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(uiColor: .systemGreen))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.peopleListBackground)
        .accessibilityHint("Выбрать человека из контактов iPhone")
    }

    private func contactRow(_ contact: SpotchatContact) -> some View {
        let peer = SpotchatPeer(
            id: contact.card.peerID,
            name: contact.card.name,
            lastConnected: contact.addedAt
        )
        return Button { open(.conversation(peer)) } label: {
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
        .listRowSeparator(.visible)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 70 }
        .listRowBackground(Color.peopleListBackground)
        .accessibilityHint("Открыть чат")
    }

    private func shareInvitation(for contact: CNContact) {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let greeting = name.isEmpty ? "Привет!" : "\(name), привет!"
        guard let url = try? service?.ownCard.invitation() else { return }
        share = SpotchatShareItem(text: "\(greeting) Добавь меня в Shum:\n\(url.absoluteString)")
    }
}

private struct ContactSection: Identifiable {
    let title: String
    let contacts: [SpotchatContact]
    var id: String { title }
}
#endif
