import BitFoundation
import Foundation
import Testing
@testable import Shum

/// Chat bubbles and the chat list share one receipt: a clock while in
/// transit, one check once delivered and two checks once read.
@Suite("Delivery receipt")
@MainActor
struct ShumDeliveryReceiptTests {
    @Test func eachDeliveryStateHasOneSymbol() {
        let date = Date(timeIntervalSince1970: 0)
        let expected: [(DeliveryStatus, ShumDeliveryReceipt.Symbol)] = [
            (.notSentYet, .clock),
            (.sending, .clock),
            (.sent, .clock),
            (.carried, .clock),
            (.delivered(to: "Alice", at: date), .check),
            (.partiallyDelivered(reached: 1, total: 2), .check),
            (.read(by: "Alice", at: date), .doubleCheck),
            (.failed(reason: "expired"), .failed),
        ]
        for (status, symbol) in expected {
            #expect(ShumDeliveryReceipt.symbol(for: status) == symbol, "\(String(describing: status))")
        }
    }
}
