import Foundation
import SwiftUI

@MainActor
final class CodeViewModel: ObservableObject {
    
    @Published var tgID: Int?
    @Published var code: String = ""
    @Published var tgName: String?
    @Published var tgUsername: String?
    @Published var photoS3URL: String?
    @Published var isUsernameConfirmed: Bool = false
    
    @Published var codeStatus: Bool?
    @Published var isLoading: Bool = false
    
    @Published var tmpTgUsername: String?
    @Published var tmpCode: String = ""
    private var tmpTgId: Int?
    private var tmpTgName: String?
    private var tmpPhotoS3URL: String?
    
    private let CODECOUNT: Int = 8
    
    func checkCode(_ input: String) {
        guard input.count == CODECOUNT else {
            codeStatus = nil
            tmpTgUsername = nil
            return
        }
        
        isLoading = true
        
        Task {
            let generator = UINotificationFeedbackGenerator()
            do {
                
                let responseData: GetUserDataByHashedCodeResponse =
                    try await FetchService.fetch
                        .fetchUserDataByHashedCode(for: input)
                
                self.tmpTgId = responseData.tgId
                self.tmpTgName = responseData.tgName
                self.tmpTgUsername = responseData.tgUsername
                self.tmpPhotoS3URL = responseData.photoS3URL
                self.codeStatus = true
                self.tmpCode = input
                generator.notificationOccurred(.success)
            } catch {
                self.tmpTgName = nil
                self.tmpTgUsername = nil
                self.codeStatus = false
                generator.notificationOccurred(.error)
            }
            
            isLoading = false
        }
    }
    
    func confirmCode() {
        
        self.tgID = tmpTgId
        self.code = tmpCode
        self.tgName = tmpTgName
        self.tgUsername = tmpTgUsername
        self.photoS3URL = tmpPhotoS3URL
        self.isUsernameConfirmed = true
        
        UserDefaults.standard.set(self.tgID, forKey: Keys.tgIdKey.rawValue)
        UserDefaults.standard.set(self.tgName, forKey: Keys.tgNameKey.rawValue)
        UserDefaults.standard.set(self.tgUsername, forKey: Keys.usernameKey.rawValue)
        UserDefaults.standard.set(self.photoS3URL, forKey: Keys.photoS3URLKey.rawValue)
        UserDefaults.standard.set(self.code, forKey: Keys.cleanCodeKey.rawValue)
    }

    func refreshProfile() async {
        let savedTGID = UserDefaults.standard.object(
            forKey: Keys.tgIdKey.rawValue
        ) as? Int

        guard let profileTGID = tgID ?? savedTGID else {
            return
        }

        isLoading = true

        defer {
            isLoading = false
        }

        do {
            let profile = try await FetchService.fetch
                .fetchUserDataByTGID(for: profileTGID)

            tgID = profileTGID
            tgName = profile.tgName
            tgUsername = profile.tgUsername
            photoS3URL = profile.photoS3URL
            isUsernameConfirmed = true

            UserDefaults.standard.set(
                profileTGID,
                forKey: Keys.tgIdKey.rawValue
            )
            UserDefaults.standard.set(
                profile.tgName,
                forKey: Keys.tgNameKey.rawValue
            )
            UserDefaults.standard.set(
                profile.tgUsername,
                forKey: Keys.usernameKey.rawValue
            )
            UserDefaults.standard.set(
                profile.photoS3URL,
                forKey: Keys.photoS3URLKey.rawValue
            )
        } catch {
            print(
                "Failed to refresh profile:",
                error.localizedDescription
            )
        }
    }

    func clearProfile() {
        tgID = nil
        code = ""
        tgName = nil
        tgUsername = nil
        photoS3URL = nil
        isUsernameConfirmed = false
        codeStatus = nil
        isLoading = false

        tmpTgUsername = nil
        tmpCode = ""
        tmpTgId = nil
        tmpTgName = nil
        tmpPhotoS3URL = nil
    }
}
