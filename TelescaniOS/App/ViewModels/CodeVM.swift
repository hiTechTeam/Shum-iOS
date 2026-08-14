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

    private let codeCount = 8

    func checkCode(_ input: String) {
        let allowed = input.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        codeStatus = input.count == codeCount && allowed ? true : nil
        tmpTgUsername = nil
    }

    @discardableResult
    func confirmCode() async -> Bool {
        guard codeStatus == true, !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let feedback = UINotificationFeedbackGenerator()
        do {
            let response = try await FetchService.fetch.link(code: tmpCode)
            apply(response.profile)
            tmpCode = ""
            codeStatus = nil
            feedback.notificationOccurred(.success)
            return true
        } catch {
            tmpTgUsername = nil
            codeStatus = false
            feedback.notificationOccurred(.error)
            return false
        }
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
