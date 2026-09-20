#if os(iOS)
import SwiftUI
import UIKit

struct ShumContactsUI: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let open: (ShumUIRoute) -> Void
    @State private var contactToRemove: ShumContact?
    @State private var removalError: String?

    private var contacts: [ShumContact] {
        guard let permanent = runtime.permanent else { return [] }
        return permanent.state.contacts
            .filter { $0.isAddressBookEntry && !permanent.isBlocked($0.card) }
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
        .alert(
            "Убрать из контактов?",
            isPresented: Binding(
                get: { contactToRemove != nil },
                set: { if !$0 { contactToRemove = nil } }
            ),
            presenting: contactToRemove
        ) { contact in
            Button("Отмена", role: .cancel) { contactToRemove = nil }
            Button("Убрать из контактов", role: .destructive) {
                removeFromContacts(contact)
            }
        } message: { _ in
            Text("Пользователь исчезнет из Контактов. Переписка и возможность общения сохранятся.")
        }
        .alert(
            "Shum",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("Понятно") { removalError = nil }
        } message: {
            Text(removalError ?? "")
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
        return ShumContactPressButton(action: { open(.conversation(peer)) }) {
            HStack(spacing: 12) {
                ShumProfileAvatar(
                    name: runtime.displayName(peer),
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
        .contextMenu {
            Button {
                open(.conversation(peer))
            } label: {
                Label("Написать", systemImage: "paperplane")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)

            Divider()

            Button(role: .destructive) {
                contactToRemove = contact
            } label: {
                Label("Убрать из контактов", systemImage: "person.crop.circle.badge.minus")
                    .foregroundStyle(.red)
            }
            .tint(.red)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(showsDivider ? .visible : .hidden, edges: .bottom)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 70 }
        .listRowBackground(ShumThemeCanvas())
        .accessibilityHint("Открыть чат")
    }

    private func removeFromContacts(_ contact: ShumContact) {
        do {
            try runtime.permanent?.removeFromContacts(contact.card)
        } catch {
            removalError = error.localizedDescription
        }
        contactToRemove = nil
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

struct ShumNewMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let select: (ShumPeer) -> Void
    @State private var query = ""

    private var contacts: [ShumContact] {
        guard let permanent = runtime.permanent else { return [] }
        return permanent.state.contacts
            .filter { $0.isAddressBookEntry && !permanent.isBlocked($0.card) }
            .filter { contact in
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || contact.card.name.localizedCaseInsensitiveContains(trimmed)
            }
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
        NavigationStack {
            contactList
            .navigationTitle("Написать сообщение")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Поиск"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Закрыть")
                }
            }
        }
        .tint(palette.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var contactList: some View {
        ScrollViewReader { proxy in
            List { contactSections }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(ShumThemeCanvas().ignoresSafeArea())
                .overlay(alignment: .trailing) { alphabetIndex(proxy: proxy) }
                .overlay { emptyState }
        }
    }

    @ViewBuilder
    private var contactSections: some View {
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

    @ViewBuilder
    private func alphabetIndex(proxy: ScrollViewProxy) -> some View {
        if query.isEmpty, sections.count > 1 {
            ContactAlphabetIndex(titles: sections.map(\.title)) { title in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(title, anchor: .top)
                }
            }
            .padding(.trailing, 2)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if contacts.isEmpty {
            let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(spacing: 14) {
                Image(systemName: hasQuery ? "magnifyingglass" : "person.2")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(hasQuery ? "Ничего не найдено" : "Контактов пока нет")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
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
        return ShumContactPressButton(action: { select(peer) }) {
            HStack(spacing: 12) {
                ShumProfileAvatar(
                    name: runtime.displayName(peer),
                    size: 48,
                    imageData: runtime.profile(for: peer.id)?.avatar ?? contact.avatar
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.displayName(peer))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(contactStatus(for: peer))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(contactStatusColor(for: peer))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(showsDivider ? .visible : .hidden, edges: .bottom)
        .listRowSeparatorTint(Color(uiColor: .separator))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
        .listRowBackground(ShumThemeCanvas())
        .accessibilityHint("Открыть чат")
    }

    private func contactStatus(for peer: ShumPeer) -> String {
        let nearby = runtime.isNearby(peer.id)
        let online = runtime.isOnline(peer.id)
        if nearby && online { return "В сети · Рядом" }
        if nearby { return "Рядом" }
        if online { return "В сети" }
        guard let date = runtime.lastActiveAt(peer.id) else { return "Давно не в сети" }
        if Date().timeIntervalSince(date) < 60 { return "был(а) только что" }
        let relative = Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        return "был(а) \(relative)"
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

private struct ShumContactPressButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    @State private var keepsHighlight = false

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            keepsHighlight = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    keepsHighlight = false
                }
            }
        } label: {
            label
        }
        .buttonStyle(ShumContactPressedStyle(keepsHighlight: keepsHighlight))
    }
}

private struct ShumContactPressedStyle: ButtonStyle {
    let keepsHighlight: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed || keepsHighlight
        configuration.label
            .background(highlighted ? Color(uiColor: .secondarySystemFill) : .clear)
            .animation(.easeOut(duration: 0.12), value: highlighted)
    }
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
