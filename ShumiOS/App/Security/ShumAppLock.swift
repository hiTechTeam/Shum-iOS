import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

@MainActor
final class ShumAppLock: ObservableObject {
    enum PreferredMethod: String {
        case biometrics
        case passcode
        case none
    }

    static let shared = ShumAppLock()

    @Published private(set) var isBiometricsEnabled: Bool
    @Published private(set) var hasPasscode: Bool
    @Published private(set) var preferredMethod: PreferredMethod
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published var errorMessage: String?

    private struct PasscodeRecord: Codable {
        let salt: Data
        let digest: Data
    }

    private let biometricsEnabledKey = "shum.security.appLock.enabled"
    private let preferredMethodKey = "shum.security.appLock.preferredMethod"
    private let passcodeKey = "shum.security.appLock.passcode"
    private let biometryDomainStateKey = "shum.security.appLock.biometryDomainState"
    private let failedAttemptsKey = "shum.security.appLock.failedAttempts"
    private let lockoutUntilKey = "shum.security.appLock.lockoutUntil"
    private var latestBiometryDomainState: Data?
    private var automaticUnlockAttempted = false

    private init(defaults: UserDefaults = .standard) {
        let biometricsEnabled = defaults.bool(forKey: biometricsEnabledKey)
        let passcodeExists = (try? KeychainStore.shared.data(for: passcodeKey)) != nil
        let storedMethod = defaults.string(forKey: preferredMethodKey)
            .flatMap(PreferredMethod.init(rawValue:))

        let resolvedMethod = storedMethod
            ?? (biometricsEnabled ? .biometrics : .passcode)
        isBiometricsEnabled = biometricsEnabled
        hasPasscode = passcodeExists
        preferredMethod = resolvedMethod
        isLocked = resolvedMethod != .none
            && (biometricsEnabled || passcodeExists)
    }

    var isEnabled: Bool { isBiometricsEnabled }

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

    var preferredMethodTitle: String {
        switch preferredMethod {
        case .biometrics where isBiometricsEnabled:
            biometricTitle
        case .none:
            "Без проверки".localized
        default:
            "Код Shum".localized
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

    func setPasscode(_ passcode: String) async -> Bool {
        guard Self.isValid(passcode) else {
            errorMessage = "Код должен состоять из пяти цифр.".localized
            return false
        }

        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            errorMessage = "Не удалось создать защищённый код. Попробуйте ещё раз.".localized
            return false
        }

        let salt = Data(saltBytes)
        let digest = await Task.detached(priority: .userInitiated) {
            Self.deriveDigest(passcode: passcode, salt: salt)
        }.value
        let record = PasscodeRecord(salt: salt, digest: digest)

        do {
            let encoded = try JSONEncoder().encode(record)
            try KeychainStore.shared.set(encoded, for: passcodeKey)
            hasPasscode = true
            clearFailedAttempts()
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Не удалось сохранить код в защищённом хранилище.".localized
            return false
        }
    }

    func verifyPasscode(_ passcode: String) async -> Bool {
        guard Self.isValid(passcode) else { return false }
        guard !isPasscodeTemporarilyLocked else {
            errorMessage = lockoutMessage
            return false
        }

        do {
            guard let encoded = try KeychainStore.shared.data(for: passcodeKey) else {
                hasPasscode = false
                errorMessage = "Код Shum не найден.".localized
                return false
            }
            let record = try JSONDecoder().decode(PasscodeRecord.self, from: encoded)
            let candidate = await Task.detached(priority: .userInitiated) {
                Self.deriveDigest(passcode: passcode, salt: record.salt)
            }.value

            guard Self.constantTimeEqual(candidate, record.digest) else {
                registerFailedAttempt()
                errorMessage = isPasscodeTemporarilyLocked
                    ? lockoutMessage
                    : "Неверный код.".localized
                return false
            }

            clearFailedAttempts()
            isLocked = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Не удалось проверить код Shum.".localized
            return false
        }
    }

    func usePasscodeByDefault() {
        guard hasPasscode else { return }
        preferredMethod = .passcode
        UserDefaults.standard.set(preferredMethod.rawValue, forKey: preferredMethodKey)
        errorMessage = nil
    }

    func useBiometricsByDefault() {
        guard isBiometricsEnabled else { return }
        preferredMethod = .biometrics
        UserDefaults.standard.set(preferredMethod.rawValue, forKey: preferredMethodKey)
        errorMessage = nil
    }

    func useNoVerification() {
        preferredMethod = .none
        UserDefaults.standard.set(preferredMethod.rawValue, forKey: preferredMethodKey)
        automaticUnlockAttempted = false
        isLocked = false
        errorMessage = nil
    }

    func enable() async -> Bool {
        errorMessage = nil
        guard await authenticate(
            reason: String.localizedFormat("Подтвердите, что хотите открывать Shum с %@.".localized, biometricTitle),
            validateEnrollment: false
        ) else { return false }

        guard let domainState = latestBiometryDomainState else {
            errorMessage = "Не удалось проверить настройки биометрии устройства.".localized
            return false
        }

        do {
            try KeychainStore.shared.set(domainState, for: biometryDomainStateKey)
        } catch {
            errorMessage = "Не удалось защитить настройку Face ID.".localized
            return false
        }

        UserDefaults.standard.set(true, forKey: biometricsEnabledKey)
        preferredMethod = .biometrics
        UserDefaults.standard.set(preferredMethod.rawValue, forKey: preferredMethodKey)
        isBiometricsEnabled = true
        isLocked = false
        errorMessage = nil
        return true
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: biometricsEnabledKey)
        preferredMethod = .passcode
        UserDefaults.standard.set(preferredMethod.rawValue, forKey: preferredMethodKey)
        try? KeychainStore.shared.remove(biometryDomainStateKey)
        isBiometricsEnabled = false
        errorMessage = nil
    }

    func lock() {
        guard preferredMethod != .none else {
            isLocked = false
            return
        }
        guard isBiometricsEnabled || hasPasscode else { return }
        if !isLocked {
            automaticUnlockAttempted = false
        }
        isLocked = true
    }

    @discardableResult
    func unlock() async -> Bool {
        guard preferredMethod != .none else {
            isLocked = false
            return true
        }
        guard isBiometricsEnabled || hasPasscode else {
            isLocked = false
            return true
        }
        guard isLocked else { return true }
        guard preferredMethod == .biometrics, isBiometricsEnabled else {
            return false
        }
        guard !automaticUnlockAttempted else { return false }
        automaticUnlockAttempted = true
        return await unlockWithBiometrics()
    }

    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard isBiometricsEnabled, isLocked else { return !isLocked }
        errorMessage = nil
        let unlocked = await authenticate(
            reason: "Откройте Shum, чтобы прочитать сообщения.".localized,
            validateEnrollment: true
        )
        if unlocked {
            if let domainState = latestBiometryDomainState {
                try? KeychainStore.shared.set(domainState, for: biometryDomainStateKey)
            }
            isLocked = false
            errorMessage = nil
        }
        return unlocked
    }

    func reset() {
        UserDefaults.standard.removeObject(forKey: biometricsEnabledKey)
        UserDefaults.standard.removeObject(forKey: preferredMethodKey)
        clearFailedAttempts()
        try? KeychainStore.shared.remove(passcodeKey)
        try? KeychainStore.shared.remove(biometryDomainStateKey)
        isBiometricsEnabled = false
        hasPasscode = false
        preferredMethod = .passcode
        isLocked = false
        isAuthenticating = false
        automaticUnlockAttempted = false
        errorMessage = nil
    }

    private var isPasscodeTemporarilyLocked: Bool {
        UserDefaults.standard.double(forKey: lockoutUntilKey) > Date().timeIntervalSince1970
    }

    private var lockoutMessage: String {
        let until = UserDefaults.standard.double(forKey: lockoutUntilKey)
        let seconds = max(1, Int(ceil(until - Date().timeIntervalSince1970)))
        return String.localizedFormat("Слишком много попыток. Повторите через %@ сек.".localized, seconds)
    }

    private func registerFailedAttempt() {
        let attempts = UserDefaults.standard.integer(forKey: failedAttemptsKey) + 1
        UserDefaults.standard.set(attempts, forKey: failedAttemptsKey)
        guard attempts >= 5 else { return }
        let delay: TimeInterval = attempts >= 10 ? 300 : 30
        UserDefaults.standard.set(
            Date().addingTimeInterval(delay).timeIntervalSince1970,
            forKey: lockoutUntilKey
        )
    }

    private func clearFailedAttempts() {
        UserDefaults.standard.removeObject(forKey: failedAttemptsKey)
        UserDefaults.standard.removeObject(forKey: lockoutUntilKey)
    }

    private func authenticate(
        reason: String,
        validateEnrollment: Bool
    ) async -> Bool {
        guard !isAuthenticating else { return false }

        let context = LAContext()
        context.localizedCancelTitle = Inc.Common.cancel.localized
        context.localizedFallbackTitle = ""
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &availabilityError
        ) else {
            errorMessage = availabilityError?.localizedDescription
                ?? "Биометрическая защита недоступна на этом устройстве.".localized
            return false
        }

        let currentDomainState = context.evaluatedPolicyDomainState
        if validateEnrollment,
           let expectedDomainState = try? KeychainStore.shared.data(for: biometryDomainStateKey),
           expectedDomainState != currentDomainState {
            disable()
            errorMessage = "Настройки Face ID изменились. Войдите по коду Shum и включите Face ID заново.".localized
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if !success {
                errorMessage = "Не удалось подтвердить владельца устройства.".localized
            } else {
                latestBiometryDomainState = context.evaluatedPolicyDomainState
            }
            return success
        } catch let error as LAError {
            if error.code != .userCancel && error.code != .appCancel
                && error.code != .systemCancel && error.code != .userFallback {
                errorMessage = error.localizedDescription
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    nonisolated private static func isValid(_ passcode: String) -> Bool {
        passcode.count == 5 && passcode.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value))
        }
    }

    nonisolated private static func deriveDigest(passcode: String, salt: Data) -> Data {
        var value = salt + Data(passcode.utf8)
        for _ in 0..<60_000 {
            value = Data(SHA256.hash(data: value + salt))
        }
        return value
    }

    nonisolated private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
