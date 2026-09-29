#if os(iOS)
import BitFoundation
import SwiftUI

/// The single delivery indicator for outgoing messages. Bubbles and the chat
/// list both render it, so a message never shows different states in them.
struct ShumDeliveryReceipt: View {
    enum Symbol: Equatable {
        /// In transit: not yet confirmed by the recipient's device.
        case clock
        /// Delivered to the recipient's device.
        case check
        /// Read by the recipient.
        case doubleCheck
        case failed
    }

    let status: DeliveryStatus
    var color: Color = .secondary
    var readColor: Color = .accentColor

    static func symbol(for status: DeliveryStatus) -> Symbol {
        switch status {
        case .notSentYet, .sending, .sent, .carried: .clock
        case .delivered, .partiallyDelivered: .check
        case .read: .doubleCheck
        case .failed: .failed
        }
    }

    static func description(for status: DeliveryStatus) -> String {
        switch symbol(for: status) {
        case .clock: "Отправляется".localized
        case .check: "Доставлено".localized
        case .doubleCheck: "Прочитано".localized
        case .failed: "Не доставлено".localized
        }
    }

    var body: some View {
        switch Self.symbol(for: status) {
        case .clock:
            Image(systemName: "clock").foregroundStyle(color)
        case .check:
            Image(systemName: "checkmark").foregroundStyle(color)
        case .doubleCheck:
            ShumDoubleCheck().stroke(readColor, style: Self.stroke).frame(width: 16, height: 10)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private static let stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
}
#endif
