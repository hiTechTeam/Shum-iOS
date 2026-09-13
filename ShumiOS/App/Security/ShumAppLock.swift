import Foundation
import LocalAuthentication
import Combine

@MainActor
final class ShumAppLock: ObservableObject {
    static let shared = ShumAppLock()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published var errorMessage: String?

    private let enabledKey = "shum.security.appLock.enabled"

    private init(defaults: UserDefaults = .standard) {
        let enabled = defaults.bool(forKey: enabledKey)
        isEnabled = enabled
        isLocked = enabled
    }

    var biometricTitle: String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        switch context.biometryType {
        case .touchID: return "Touch ID"
        default: return "Face ID"
        }
    }

    var isBiometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    func enable() async -> Bool {
        guard await authenticate(
            policy: .deviceOwnerAuthenticationWithBiometrics,
            reason: "Подтвердите, что хотите защитить доступ к Shum."
        ) else { return false }

        UserDefaults.standard.set(true, forKey: enabledKey)
        isEnabled = true
        isLocked = false
        errorMessage = nil
        return true
    }

    func disable() async -> Bool {
        guard await authenticate(
            policy: .deviceOwnerAuthentication,
            reason: "Подтвердите отключение защиты Shum."
        ) else { return false }

        UserDefaults.standard.set(false, forKey: enabledKey)
        isEnabled = false
        isLocked = false
        errorMessage = nil
        return true
    }

    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    @discardableResult
    func unlock() async -> Bool {
        guard isEnabled else {
            isLocked = false
            return true
        }
        guard isLocked else { return true }

        let unlocked = await authenticate(
            policy: .deviceOwnerAuthentication,
            reason: "Откройте Shum, чтобы прочитать сообщения."
        )
        if unlocked {
            isLocked = false
            errorMessage = nil
        }
        return unlocked
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: enabledKey)
        isEnabled = false
        isLocked = false
        isAuthenticating = false
        errorMessage = nil
    }

    private func authenticate(
        policy: LAPolicy,
        reason: String
    ) async -> Bool {
        guard !isAuthenticating else { return false }

        let context = LAContext()
        context.localizedCancelTitle = Inc.Common.cancel.localized
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(policy, error: &availabilityError) else {
            errorMessage = availabilityError?.localizedDescription
                ?? "Биометрическая защита недоступна на этом устройстве."
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: reason
            )
            if !success {
                errorMessage = "Не удалось подтвердить владельца устройства."
            }
            return success
        } catch let error as LAError {
            if error.code != .userCancel && error.code != .appCancel
                && error.code != .systemCancel {
                errorMessage = error.localizedDescription
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
