import SwiftUI

enum ShumChatProtectionState: Equatable {
    case encrypted, preparing, unavailable, archive

    init(isReady: Bool, isArchive: Bool, hasRecipientKey: Bool,
         session: LazyHandshakeState, hasSessionKey: Bool) {
        if isArchive { self = .archive }
        else if !isReady { self = .unavailable }
        else if hasRecipientKey { self = .encrypted }
        else {
            switch session {
            case .established: self = hasSessionKey ? .encrypted : .preparing
            case .failed: self = .unavailable
            default: self = .preparing
            }
        }
    }

    var title: String {
        switch self {
        case .encrypted: "Сквозное шифрование".localized
        case .preparing: "Подготавливаем защищённый чат…".localized
        case .unavailable: "Защищённый чат недоступен".localized
        case .archive: "Сохранённая история".localized
        }
    }

    var symbol: String {
        switch self {
        case .encrypted: "lock.fill"
        case .preparing: "lock"
        case .unavailable: "exclamationmark.shield"
        case .archive: "clock.arrow.circlepath"
        }
    }

    var explanation: String {
        switch self {
        case .encrypted:
            "Сообщения шифруются на вашем устройстве. Читать переписку могут только её участники, а ретрансляторы не видят текст сообщений.".localized
        case .preparing:
            "Ждём ключ собеседника или завершения защищённого соединения. Сообщения не отправляются открытым текстом.".localized
        case .unavailable:
            "Сейчас не удалось подготовить защиту для отправки сообщений. Незашифрованная отправка не используется.".localized
        case .archive:
            "Это сохранённая история старого чата. Новые сообщения в этот чат не отправляются.".localized
        }
    }
}

struct ShumChatProtectionBanner: View {
    let state: ShumChatProtectionState
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Image(systemName: state.symbol)
                Text(state.title + " · Децентрализованная связь".localized)
                    .multilineTextAlignment(.center)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.title + ". Децентрализованная связь".localized)
        .accessibilityHint("Узнать о защите переписки".localized)
        .accessibilityIdentifier("shum.chatProtection")
    }
}

struct ShumChatProtectionSheet: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showVerification = false
    private var state: ShumChatProtectionState { runtime.chatProtection(for: peer.id) }
    private var card: ShumContactCard? { runtime.permanent?.card(for: peer.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ShumInfoRow(title: state.title, text: state.explanation, symbol: state.symbol, isActive: state == .encrypted)
                    ShumInfoRow(title: "Децентрализованная связь".localized, text:
                        "Рядом сообщения передаются по Bluetooth. Для связи через интернет используются независимые ретрансляторы. Единого центрального сервера переписки нет.".localized,
                        symbol: "network")

                    VStack(spacing: 12) {
                        RegistrationPrimaryButton(
                            title: "Сверить ключ".localized,
                            isEnabled: card != nil,
                            trailingSystemImage: "checkmark.shield"
                        ) { showVerification = true }
                        Text(card != nil
                             ? "Сравните QR-код с собеседником лично, находясь рядом.".localized
                             : "Сверка ключа станет доступна после получения профиля собеседника.".localized)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("Защита чата".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово".localized) { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(470), .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showVerification) {
            if let card {
                ShumKeyVerificationView(runtime: runtime, peerCard: card)
            }
        }
    }
}

/// An explanation with a tinted symbol, shared by the information sheets.
struct ShumInfoRow: View {
    let title: String
    let text: String
    let symbol: String
    var isActive = true
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isActive ? palette.accent : Color.secondary)
                .frame(width: 38, height: 38)
                .background((isActive ? palette.accent : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opened from the status line on the chat list: what end-to-end encryption,
/// Bluetooth and the Nostr relays mean, and what the current status says.
struct ShumNetworkInfoSheet: View {
    @ObservedObject var runtime: ShumRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if runtime.internetConnected {
                        ShumInfoRow(title: "Nostr подключён".localized, text:
                            "Shum на связи с ретрансляторами. Сообщения доставляются через интернет, даже если собеседник далеко.".localized,
                            symbol: "checkmark.circle")
                    } else {
                        ShumInfoRow(title: "Ожидаем сеть".localized, text:
                            "Сейчас нет связи с ретрансляторами. Как только появится интернет, Shum подключится сам и отправит сообщения из очереди. Рядом Bluetooth работает и без сети.".localized,
                            symbol: "wifi.slash", isActive: false)
                    }
                    ShumInfoRow(title: "Сквозное шифрование".localized, text:
                        "Сообщения шифруются на вашем телефоне ещё до отправки. Прочитать их может только собеседник: ни ретрансляторы, ни сервер уведомлений текста не видят.".localized,
                        symbol: "lock.fill")
                    ShumInfoRow(title: "Рядом по Bluetooth".localized, text:
                        "Если собеседник рядом, сообщения идут напрямую с телефона на телефон, интернет для этого не нужен. Другие телефоны с Shum могут передать сообщение дальше, не видя его текста.".localized,
                        symbol: "antenna.radiowaves.left.and.right")
                    ShumInfoRow(title: "На расстоянии через Nostr".localized, text:
                        "Через интернет сообщения передаются через независимые ретрансляторы открытой сети Nostr. У неё нет единого владельца, а ретрансляторы получают только зашифрованные пакеты.".localized,
                        symbol: "network")
                }
                .padding(24)
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("Как работает связь".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово".localized) { dismiss() }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
