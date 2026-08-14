import Foundation
import SwiftUI

@MainActor
final class CodeViewModel: ObservableObject {
    @Published var telescanID: UUID?
    @Published var tgName: String?
    @Published var tgUsername: String?
    @Published var photoS3URL: String?
    @Published var isUsernameConfirmed = false
    @Published var codeStatus: Bool?
    @Published var isLoading = false
    @Published var tmpTgUsername: String?
    @Published var tmpCode = ""

    private let linkAction: @MainActor (String) async throws -> LinkDeviceResponse
    private var linkTask: Task<Void, Never>?
    private let codeCount = 8

    init(
        linkAction: @escaping @MainActor (String) async throws -> LinkDeviceResponse = {
            try await FetchService.fetch.link(code: $0)
        }
    ) {
        self.linkAction = linkAction
    }

    func checkCode(_ input: String) {
        let normalizedCode = input.uppercased()
        let allowed = normalizedCode.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }

        guard normalizedCode.count == codeCount else {
            linkTask?.cancel()
            linkTask = nil
            isLoading = false
            codeStatus = nil
            tmpTgUsername = nil
            return
        }

        guard allowed else {
            linkTask?.cancel()
            linkTask = nil
            isLoading = false
            tmpTgUsername = nil
            if codeStatus != false {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            codeStatus = false
            return
        }

        guard !isLoading, codeStatus != true else { return }
        isLoading = true
        codeStatus = nil
        tmpTgUsername = nil

        linkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoading = false
                linkTask = nil
            }

            let feedback = UINotificationFeedbackGenerator()
            do {
                let response = try await linkAction(normalizedCode)
                guard !Task.isCancelled,
                      tmpCode.uppercased() == normalizedCode else { return }
                apply(response.profile)
                codeStatus = true
                feedback.notificationOccurred(.success)
            } catch is CancellationError {
                return
            } catch {
                guard tmpCode.uppercased() == normalizedCode else { return }
                tmpTgUsername = nil
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

    func resetCodeEntry() {
        linkTask?.cancel()
        linkTask = nil
        codeStatus = nil
        isLoading = false
        tmpTgUsername = nil
        tmpCode = ""
    }

    func refreshProfile() async {
        guard AuthSessionStore.shared.hasTokens else { return }
        isLoading = true
        defer { isLoading = false }
        if let profile = try? await FetchService.fetch.currentProfile() {
            apply(profile)
        }
    }

    func restoreLocalProfile() {
        if let value = UserDefaults.standard.string(
            forKey: Keys.telescanIDKey.rawValue
        ) {
            telescanID = UUID(uuidString: value)
        }
        tgName = UserDefaults.standard.string(forKey: Keys.tgNameKey.rawValue)
        tgUsername = UserDefaults.standard.string(forKey: Keys.usernameKey.rawValue)
        photoS3URL = UserDefaults.standard.string(forKey: Keys.photoS3URLKey.rawValue)
        isUsernameConfirmed = telescanID != nil
    }

    func clearProfile() {
        linkTask?.cancel()
        linkTask = nil
        telescanID = nil
        tgName = nil
        tgUsername = nil
        photoS3URL = nil
        isUsernameConfirmed = false
        codeStatus = nil
        isLoading = false
        tmpTgUsername = nil
        tmpCode = ""
    }

    private func apply(_ profile: TelescanProfileResponse) {
        telescanID = profile.telescanId
        tgName = profile.name
        tgUsername = profile.username.map { $0.hasPrefix("@") ? $0 : "@" + $0 }
        photoS3URL = profile.photoUrl
        tmpTgUsername = tgUsername
        isUsernameConfirmed = true
        UserDefaults.standard.set(
            profile.telescanId.uuidString.lowercased(),
            forKey: Keys.telescanIDKey.rawValue
        )
        UserDefaults.standard.set(profile.name, forKey: Keys.tgNameKey.rawValue)
        UserDefaults.standard.set(tgUsername, forKey: Keys.usernameKey.rawValue)
        UserDefaults.standard.set(profile.photoUrl, forKey: Keys.photoS3URLKey.rawValue)
    }
}
