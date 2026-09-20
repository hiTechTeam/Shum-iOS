#if os(iOS)
import SwiftUI
import UIKit

struct ShumContactsUI: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let open: (ShumUIRoute) -> Void

    private var contacts: [ShumContact] {
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
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(
                            Array(section.contacts.enumerated()),
                            id: \.element.id
                        ) { index, contact in
                            contactRow(
                                contact,
                                showsDivider: index < section.contacts.count - 1
                            )
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                    .id(section.id)
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ShumThemeCanvas().ignoresSafeArea())
            .overlay(alignment: .trailing) {
                if sections.count > 1 {
                    ContactAlphabetIndex(titles: sections.map(\.title)) {
                        title in
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(title, anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
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
            .tint(palette.accent)
            .accessibilityLabel("Новый контакт")
            .accessibilityIdentifier("shum.addContact")
        } else {
            Button { openNewContact() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(palette.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Новый контакт")
            .accessibilityIdentifier("shum.addContact")
        }
    }

    private func openNewContact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        open(.newChat)
    }

    private func contactRow(
        _ contact: ShumContact,
        showsDivider: Bool
    ) -> some View {
        let peer = ShumPeer(
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.displayName(peer))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(contactStatus(for: peer))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(contactStatusColor(for: peer))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(showsDivider ? .visible : .hidden, edges: .bottom)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 70 }
        .listRowBackground(ShumThemeCanvas())
        .accessibilityHint("Открыть чат")
    }

    private func contactStatus(for peer: ShumPeer) -> String {
        let nearby = runtime.isNearby(peer.id)
        let online = runtime.isOnline(peer.id)
        if nearby && online { return "В сети · Рядом" }
        if nearby { return "Рядом" }
        if online { return "В сети" }
        guard let date = runtime.lastActiveAt(peer.id) else {
            return "Давно не в сети"
        }
        if Date().timeIntervalSince(date) < 60 {
            return "был(а) только что"
        }
        let relativeDate = Self.relativeDateFormatter.localizedString(
            for: date,
            relativeTo: Date()
        )
        return "был(а) \(relativeDate)"
    }

    private func contactStatusColor(for peer: ShumPeer) -> Color {
        runtime.isNearby(peer.id) || runtime.isOnline(peer.id)
            ? Color(uiColor: .systemGreen)
            : .secondary
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

}

private struct ContactAlphabetIndex: View {
    @Environment(\.shumThemePalette) private var palette
    let titles: [String]
    let select: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ForEach(titles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.vertical, 5)
            .frame(width: 22, height: indexHeight, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !titles.isEmpty else { return }
                        let availableHeight = max(1, indexHeight - 10)
                        let y = min(
                            max(0, value.location.y - 5),
                            availableHeight - 0.001
                        )
                        let index = min(
                            titles.count - 1,
                            Int(y / availableHeight * CGFloat(titles.count))
                        )
                        select(titles[index])
                    }
            )
            .position(
                x: proxy.size.width - 11,
                y: proxy.size.height / 2
            )
        }
        .frame(width: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Алфавитный указатель")
    }

    private var indexHeight: CGFloat {
        min(420, max(44, CGFloat(titles.count) * 17 + 10))
    }
}

private struct ContactSection: Identifiable {
    let title: String
    let contacts: [ShumContact]
    var id: String { title }
}
#endif
