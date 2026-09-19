#if os(iOS)
import SwiftUI
import UIKit

struct ShumContactsUI: View {
    @Environment(\.shumThemePalette) private var palette
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
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle("Контакты")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if contacts.isEmpty {
                VStack(spacing: 0) {
                    ShumPixelEmptyIcon(kind: .contacts)
                        .foregroundStyle(.primary)
                        .frame(width: 88, height: 68)
                        .accessibilityHidden(true)

                    Text("Контактов пока нет")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 26)

                    Text("Добавленные контакты появятся здесь.")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
                .frame(maxWidth: 330)
                .padding(.horizontal, 24)
                .accessibilityElement(children: .contain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                newContactButton
            }
        }
    }

    @ViewBuilder
    private var newContactButton: some View {
        if #available(iOS 26.0, *) {
            Button { openNewContact() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Color.accentColor)
            .accessibilityLabel("Новый контакт")
            .accessibilityIdentifier("spotchat.addContact")
        } else {
            Button { openNewContact() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Новый контакт")
            .accessibilityIdentifier("spotchat.addContact")
        }
    }

    private func openNewContact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        open(.newChat)
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
        .listRowBackground(ShumThemeCanvas())
        .accessibilityHint("Открыть чат")
    }

}

private struct ContactSection: Identifiable {
    let title: String
    let contacts: [SpotchatContact]
    var id: String { title }
}
#endif
