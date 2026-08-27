import Foundation
import SwiftUI

enum CodeEntryError: Equatable {
    case invalidCode
    case telegramUsernameRequired

    var localizedMessage: String {
        switch self {
        case .invalidCode:
            Inc.Registration.incorrectCode.localized
        case .telegramUsernameRequired:
            Inc.Registration.telegramUsernameRequired.localized
        }
    }
}

@MainActor
final class CodeViewModel: ObservableObject {
    @Published var telescanID: UUID?
    @Published var tgName: String?
    @Published var tgUsername: String?
    @Published var bio: String?
    @Published var photoS3URL: String?
    @Published var isUsernameConfirmed = false
    @Published var codeStatus: Bool?
    @Published var codeError: CodeEntryError?
    @Published var isLoading = false
    @Published var isSavingBio = false
    @Published var bioSaveFailed = false
    @Published var isUnlinkingTelegram = false
    @Published var telegramUnlinkFailed = false
    @Published var tmpTgUsername: String?
    @Published var tmpCode = ""

    private let linkAction: @MainActor (String) async throws -> TelegramLinkResponse
    private let updateBioAction: @MainActor (String?) async throws
        -> TelescanProfileResponse
    private let unlinkTelegramAction: @MainActor () async throws
        -> TelescanProfileResponse
    private var linkTask: Task<Void, Never>?
    private var pendingCode: String?
    private let codeCount = 8

    init(
        linkAction: @escaping @MainActor (String) async throws -> TelegramLinkResponse = {
            try await FetchService.fetch.linkTelegram(code: $0)
        }
    ) {
        self.linkAction = linkAction
        self.updateBioAction = {
            try await FetchService.fetch.updateProfile(bio: $0)
        }
        self.unlinkTelegramAction = {
            try await FetchService.fetch.unlinkTelegram()
        }
    }

    init(
        linkAction: @escaping @MainActor (String) async throws -> TelegramLinkResponse,
        updateBioAction: @escaping @MainActor (String?) async throws
            -> TelescanProfileResponse,
        unlinkTelegramAction: @escaping @MainActor () async throws
            -> TelescanProfileResponse = {
                try await FetchService.fetch.unlinkTelegram()
            }
    ) {
        self.linkAction = linkAction
        self.updateBioAction = updateBioAction
        self.unlinkTelegramAction = unlinkTelegramAction
    }

    func checkCode(_ input: String) {
        let normalizedCode = input.uppercased()
        let allowed = normalizedCode.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }

        guard normalizedCode.count == codeCount else {
            invalidateCodeCheck()
            return
        }

        guard allowed else {
            linkTask?.cancel()
            linkTask = nil
            pendingCode = nil
            isLoading = false
            tmpTgUsername = nil
            codeError = .invalidCode
            if codeStatus != false {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            codeStatus = false
            return
        }

        guard pendingCode != normalizedCode
                || (!isLoading && codeStatus != true) else { return }

        linkTask?.cancel()
        pendingCode = normalizedCode
        isLoading = true
        codeStatus = nil
        codeError = nil
        tmpTgUsername = nil

        linkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pendingCode == normalizedCode {
                    isLoading = false
                    linkTask = nil
                }
            }

            let feedback = UINotificationFeedbackGenerator()
            do {
                let response = try await linkAction(normalizedCode)
                guard !Task.isCancelled,
                      tmpCode.uppercased() == normalizedCode else { return }
                ProfileCache.clear()
                applyProfile(response.profile)
                codeStatus = true
                codeError = nil
                feedback.notificationOccurred(.success)
            } catch is CancellationError {
                return
            } catch APIClientError.telegramUsernameRequired {
                guard tmpCode.uppercased() == normalizedCode else { return }
                tmpTgUsername = nil
                codeError = .telegramUsernameRequired
                codeStatus = false
                feedback.notificationOccurred(.error)
            } catch {
                guard tmpCode.uppercased() == normalizedCode else { return }
                tmpTgUsername = nil
                codeError = .invalidCode
                codeStatus = false
                feedback.notificationOccurred(.error)
            }
        }
    }

    @discardableResult
    func confirmCode() async -> Bool {
        guard codeStatus == true, !isLoading, isUsernameConfirmed else {
            return false
        }
        resetCodeEntry()
        return true
    }

    @discardableResult
    func updateBio(_ value: String) async -> Bool {
        guard !isSavingBio else { return false }
        let normalizedBio = Self.normalizedBio(value)
        guard normalizedBio != bio else { return true }

        isSavingBio = true
        bioSaveFailed = false
        defer { isSavingBio = false }
        do {
            applyProfile(try await updateBioAction(normalizedBio))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            bioSaveFailed = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func resetBioSaveState() {
        bioSaveFailed = false
    }

    @discardableResult
    func unlinkTelegram() async -> Bool {
        guard !isUnlinkingTelegram else { return false }
        isUnlinkingTelegram = true
        telegramUnlinkFailed = false
        defer { isUnlinkingTelegram = false }

        do {
            ProfileCache.clear()
            applyProfile(try await unlinkTelegramAction())
            resetCodeEntry()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            telegramUnlinkFailed = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func resetTelegramUnlinkState() {
        telegramUnlinkFailed = false
    }

    func resetCodeEntry() {
        linkTask?.cancel()
        linkTask = nil
        pendingCode = nil
        codeStatus = nil
        codeError = nil
        isLoading = false
        isSavingBio = false
        bioSaveFailed = false
        isUnlinkingTelegram = false
        telegramUnlinkFailed = false
        tmpTgUsername = nil
        tmpCode = ""
    }

    func restoreLocalProfile() {
        if let value = UserDefaults.standard.string(
            forKey: Keys.telescanIDKey.rawValue
        ) {
            telescanID = UUID(uuidString: value)
        }
        tgName = UserDefaults.standard.string(forKey: Keys.tgNameKey.rawValue)
        tgUsername = UserDefaults.standard.string(forKey: Keys.usernameKey.rawValue)
        bio = UserDefaults.standard.string(forKey: Keys.bioKey.rawValue)
        photoS3URL = UserDefaults.standard.string(forKey: Keys.photoS3URLKey.rawValue)
        isUsernameConfirmed = telescanID != nil
            && !(tgUsername?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ?? true)
    }

    func clearProfile() {
        linkTask?.cancel()
        linkTask = nil
        pendingCode = nil
        telescanID = nil
        tgName = nil
        tgUsername = nil
        bio = nil
        photoS3URL = nil
        isUsernameConfirmed = false
        codeStatus = nil
        codeError = nil
        isLoading = false
        isSavingBio = false
        bioSaveFailed = false
        isUnlinkingTelegram = false
        telegramUnlinkFailed = false
        tmpTgUsername = nil
        tmpCode = ""
    }

    func applyProfile(_ profile: TelescanProfileResponse) {
        let username = profile.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedUsername = username.flatMap { value in
            value.isEmpty ? nil : (value.hasPrefix("@") ? value : "@" + value)
        }
        telescanID = profile.telescanId
        tgName = profile.name
        tgUsername = formattedUsername
        bio = Self.normalizedBio(profile.bio)
        photoS3URL = profile.photoUrl
        tmpTgUsername = tgUsername
        isUsernameConfirmed = formattedUsername != nil
        UserDefaults.standard.set(
            profile.telescanId.uuidString.lowercased(),
            forKey: Keys.telescanIDKey.rawValue
        )
        UserDefaults.standard.set(profile.name, forKey: Keys.tgNameKey.rawValue)
        if let formattedUsername {
            UserDefaults.standard.set(
                formattedUsername,
                forKey: Keys.usernameKey.rawValue
            )
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.usernameKey.rawValue)
        }
        if let bio {
            UserDefaults.standard.set(bio, forKey: Keys.bioKey.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.bioKey.rawValue)
        }
        UserDefaults.standard.set(profile.photoUrl, forKey: Keys.photoS3URLKey.rawValue)
    }

    private static func normalizedBio(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(36))
    }

    private func invalidateCodeCheck() {
        linkTask?.cancel()
        linkTask = nil
        pendingCode = nil
        isLoading = false
        codeStatus = nil
        codeError = nil
        tmpTgUsername = nil
    }
}
