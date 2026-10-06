#if os(iOS)
import SwiftUI
import UIKit
import BitFoundation

/// Keeps the preview laid out at exactly the same width as its source row,
/// then scales the finished row into the context-menu viewport. This makes
/// every trailing element travel with the avatar instead of relaying out and
/// jumping when the menu opens.
struct ShumDirectoryContextPreview: View {
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
enum DirectoryConfirmation {
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
