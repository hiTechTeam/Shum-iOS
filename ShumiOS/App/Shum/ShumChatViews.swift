import SwiftUI
import CoreBluetooth
import BitFoundation

struct ShumChatsView: View {
    @EnvironmentObject private var chat: ShumChatRuntime
    @Environment(\.shumThemePalette) private var palette
    @State private var query = ""
    @State private var unreadOnly = false
    @State private var showPeople = false
    private var filtered: [ShumContact] {
        chat.chatContacts.filter { (!unreadOnly || chat.unread($0.id) > 0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            HStack(spacing: 8) {
                filter("Все", selected: !unreadOnly) { unreadOnly = false }
                filter("Непрочитанные", selected: unreadOnly) { unreadOnly = true }
            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            if filtered.isEmpty {
                VStack(spacing: 16) {
                    ShumLogoMark().frame(width: 64, height: 64)
                    Text(query.isEmpty ? "Разговор начинается рядом" : "Ничего не найдено").font(.title3.bold())
                    Text(query.isEmpty ? "Откройте Shum на другом iPhone поблизости и начните переписку по Bluetooth." : "Попробуйте другое имя.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if query.isEmpty { Button("Найти людей") { showPeople = true }.buttonStyle(.borderedProminent) }
                }.frame(maxWidth: .infinity).padding(.vertical, 60).listRowSeparator(.hidden)
            }
            ForEach(filtered) { contact in
                NavigationLink { ShumConversationView(contact: contact) } label: {
                    HStack(spacing: 14) {
                        ShumInitialAvatar(name: contact.name)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(contact.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                if let last = chat.conversation(contact.id).last { Text(last.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                            }
                            HStack {
                                Text(chat.conversation(contact.id).last?.text ?? "Начните разговор").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if chat.unread(contact.id) > 0 {
                                    Text("\(chat.unread(contact.id))")
                                        .font(.caption.bold())
                                        .foregroundStyle(palette.accentForeground)
                                        .padding(6)
                                        .background(Color.accentColor, in: Circle())
                                }
                            }
                        }
                    }.padding(.vertical, 7)
                }.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain).navigationTitle("Чаты")
        .searchable(text: $query, prompt: "Поиск")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
            Button { showPeople = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Новый чат")
        } }
        .sheet(isPresented: $showPeople) {
            NavigationStack { ShumPeopleView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showPeople = false } } } }
        }
    }
    private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground), in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ShumPeopleView: View {
    @EnvironmentObject private var chat: ShumChatRuntime
    @EnvironmentObject private var coordinator: AppCoordinator
    private var nearby: [ShumContact] { chat.contacts.filter { chat.nearbyIDs.contains($0.id) }.sorted { $0.name < $1.name } }
    var body: some View {
        List {
            Section {
                Toggle("Видимость рядом", isOn: Binding(get: { coordinator.isScaning }, set: coordinator.setScanning))
                    .tint(.accentColor)
            } footer: { Text("Когда видимость включена, люди поблизости могут найти вас и написать без интернета.") }
            Section {
                if nearby.isEmpty {
                    VStack(spacing: 14) {
                        Image("PixelPeople").interpolation(.none).resizable().scaledToFit().frame(width: 48, height: 48).foregroundStyle(Color.accentColor)
                        Text(statusTitle).font(.headline)
                        Text(statusDescription).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if chat.bluetoothState == .unauthorized {
                            Button("Открыть настройки") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 40).listRowBackground(Color.clear)
                }
                ForEach(nearby) { contact in
                    NavigationLink { ShumConversationView(contact: contact) } label: {
                        HStack(spacing: 14) {
                            ShumInitialAvatar(name: contact.name)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(contact.name).font(.body.weight(.semibold))
                                Text("Рядом · Bluetooth").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            } header: { Text("Люди рядом · \(nearby.count)") }
        }.listStyle(.insetGrouped).navigationTitle("Люди")
    }
    private var statusTitle: String {
        if !coordinator.isScaning { return "Видимость выключена" }
        switch chat.bluetoothState {
        case .poweredOff: return "Bluetooth выключен"
        case .unauthorized: return "Разрешите доступ к Bluetooth"
        case .unsupported: return "Bluetooth недоступен"
        default: return "Ищем людей рядом"
        }
    }
    private var statusDescription: String {
        if !coordinator.isScaning { return "Включите видимость, чтобы начать общение." }
        switch chat.bluetoothState {
        case .poweredOff: return "Включите Bluetooth в настройках iPhone."
        case .unauthorized: return "Shum использует Bluetooth для поиска людей и обмена сообщениями."
        case .unsupported: return "Для проверки переписки запустите Shum на двух настоящих iPhone."
        default: return "Откройте Shum на другом iPhone поблизости. Подключение может занять несколько секунд."
        }
    }
}

struct ShumConversationView: View {
    @EnvironmentObject private var chat: ShumChatRuntime
    let contact: ShumContact
    @State private var draft = ""
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Text(chat.nearbyIDs.contains(contact.id) ? "Рядом · без интернета" : "Сейчас не рядом")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                    ForEach(chat.conversation(contact.id)) { message in
                        HStack {
                            if message.outgoing { Spacer(minLength: 48) }
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(message.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                HStack(spacing: 5) {
                                    Text(message.date, style: .time)
                                    if message.outgoing { Text(status(message.status)) }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(message.outgoing ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                            .contextMenu {
                                if message.outgoing, case .failed = message.status {
                                    Button {
                                        chat.send(message.text, to: contact.id)
                                    } label: {
                                        Text("Отправить снова")
                                            .foregroundStyle(.primary)
                                    }
                                    .tint(.primary)
                                }
                            }
                            if !message.outgoing { Spacer(minLength: 48) }
                        }.id(message.id)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            .onAppear { chat.open(contact.id); proxy.scrollTo(chat.conversation(contact.id).last?.id, anchor: .bottom) }
            .onDisappear { chat.open(nil) }
            .shumOnChange(of: chat.conversation(contact.id).count) { _, _ in
                withAnimation { proxy.scrollTo(chat.conversation(contact.id).last?.id, anchor: .bottom) }
            }
        }
        .navigationTitle(chat.name(contact.id)).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Сообщение", text: $draft, axis: .vertical).lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 11).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                Button { if chat.send(draft, to: contact.id) { draft = "" } } label: {
                    Image(systemName: "arrow.up").font(.body.bold()).frame(width: 44, height: 44)
                }.buttonStyle(.borderedProminent).clipShape(Circle()).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить")
            }.padding(.horizontal, 14).padding(.vertical, 8).background(.bar)
        }
    }
    private func status(_ value: DeliveryStatus) -> String {
        switch value {
        case .sending, .notSentYet: return "Отправляется"
        case .sent: return "Отправлено"
        case .delivered: return "Доставлено"
        case .read: return "Прочитано"
        case .failed: return "Не отправлено"
        default: return "Ожидание"
        }
    }
}
struct ShumInitialAvatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.title2.weight(.medium))
            .foregroundStyle(Color.accentColor).frame(width: 52, height: 52).background(Color.accentColor.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}
