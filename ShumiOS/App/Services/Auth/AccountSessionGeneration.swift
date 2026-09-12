import Foundation

@MainActor
final class AccountSessionGeneration {
    static let shared = AccountSessionGeneration()

    private(set) var value = UUID()

    private init() { }

    func advance() {
        value = UUID()
    }
}
