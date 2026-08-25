import Foundation

struct Inc {
    
    // MARK: - Alerts
    struct Alerts {
        static let turnOnBLE: String = "turnOnBLE"
        // EN: Turn on Bluetooth
        // RU: Включите Bluetooth
    }
    
    // MARK: - Common
    struct Common {
        
        static let SignIn: String = "SignIn"
        // EN: Sign in
        // RU: Зарегистрироваться
        
        static let cancel: String = "cancel"
        // EN: Cancel
        // RU: Отмена
        
        static let copiedSheet: String = "copied_sheet"
        // EN: Copied
        // RU: Скопировано
        
        static let nearby: String = "nearby"
        static let distanceMetersFormat: String = "distanceMetersFormat"
        static let disappearsInSecondsFormat: String =
            "disappearsInSecondsFormat"
        static let countdownSecondsFormat: String =
            "countdownSecondsFormat"
        static let signalLostCountdownFormat: String =
            "signalLostCountdownFormat"
        // EN: Nearby
        // RU: Рядом
        
        static let okey: String = "Ok"
        static let close: String = "close"
        static let Telescan: String = "Telescan"
    }
    
    // MARK: - Tabs
    struct Tabs {
        static let chats: String = "chats"
        // EN: Chats
        // RU: Чаты

        static let settings: String = "settings"
        // EN: Settings
        // RU: Настройки
        
        static let peopleNearby: String = "peopleNearby"
        // EN: People nearby
        // RU: Люди рядом
        
        static let people: String = "people"
        // EN: People
        // RU: Люди
        
        static let profile: String = "profile"
        // EN: Profile
        // RU: Профиль
        
        static let metTitle: String = "metTitle"
        // EN: Met recently
        // RU: Виделись недавно

        static let metHeader: String = "metHeader"
        // EN: Met recently
        // RU: Виделись недавно
    }

    // MARK: - Chats
    struct Chats {
        static let unavailableTitle: String = "chatsUnavailableTitle"
        static let unavailableMessage: String = "chatsUnavailableMessage"
    }

    // MARK: - Encounter history
    struct EncounterHistory {
        static let emptyTitle: String = "encounterHistoryEmptyTitle"
        static let emptyMessage: String = "encounterHistoryEmptyMessage"
        static let clear: String = "encounterHistoryClear"
        static let clearTitle: String = "encounterHistoryClearTitle"
        static let clearMessage: String = "encounterHistoryClearMessage"
        static let lastSeenFormat: String = "encounterHistoryLastSeenFormat"
    }
    
    // MARK: - Registration
    struct Registration {
        static let placeCode: String = "placeCode"
        // EN: Code
        // RU: Код
        
        static let enterCode: String = "enterCode"
        // EN: Enter code
        // RU: Введите код
        
        static let codePlaceholder: String = "codePlaceholder"
        // EN: Code
        // RU: Код
        
        static let registration: String = "registration"
        // EN: Registration
        // RU: Регистрация
        
        static let incorrectCode: String = "incorrectCode"
        // EN: Invalid or expired code
        // RU: Код недействителен или истёк

        static let telegramUsernameRequired: String = "telegramUsernameRequired"
        // EN: Create a public Telegram username and request a new code
        // RU: Создайте публичный Telegram username и запросите новый код
        
        static let warningCharactersEight: String = "warningCharactersEight"
        // EN: Maximum of 8 characters
        // RU: Максимум 8 символов
        
        static let regDescription: String = "regDescription"
        // EN: Enter the code that the bot sent so that the application can link your tg username.
        // RU: Введите код, который отправил бот, для того чтобы приложение могло привязать ваш tg username.
        
        static let tgUsername: String = "Telegram username"
        static let usernamePlaceholder: String = "@_"
    }
    
    // MARK: - Onboarding
    struct Onboarding {
        static let welcomeTitle: String = "welcome_title"
        // EN: Welcome to Telescan
        // RU: Добро пожаловать в Telescan
        
        static let aboutOnBoardingMsg: String = "aboutOnBoardingMsg"
        // EN: Telescan lets you instantly find and share profiles.
        // RU: Telescan позволяет быстро находить и обмениваться профилями.
        
        static let shortOnboardingMsg: String = "shortOnboardingMsg"
        // EN: Share your Telegram with people around you
        // RU: Делитесь Telegram с людьми рядом
        
        static let start: String = "start"
        // EN: Get started with Telegram
        // RU: Начать с Telegram
        
        static let goNext: String = "goNext"
        // EN: Next
        // RU: Далее
        
        static let goStart: String = "go"
        // EN: Go
        // RU: Начать
        
        static let confirmButton: String = "confirmButton"
        // EN: Confirm
        // RU: Применить
        
        static let poweredByTG: String = "poweredByTG"

        static let legalAgreement: String = "legalAgreement"
        static let privacyPolicy: String = "privacyPolicy"
        static let termsOfService: String = "termsOfService"
        static let continueHint: String = "continueHint"
    }
    
    // MARK: - Scanning
    struct Scanning {
        static let emptyTitle: String = "nearbyEmptyTitle"

        static let scanning: String = "scanning"
        // EN: Scanning
        // RU: Сканирование
        
        static let justTurnScaning: String = "justTurnScaning"
        // EN: Turn on scaning
        // RU: Включите сканирование
        
        static let scanToggleDescription: String = "scanToggleDescription"
        // EN: Turn on Bluetooth scanning so that you can see people around you.
        // RU: Включите Bluetooth-сканирование, чтобы видеть людей рядом.
        
        static let turnedOffScanning: String = "turnedOffScaning"
        // EN: Scanning is turned off. Enable it to see nearby people.
        // RU: Сканирование отключено. Включите его, чтобы видеть людей рядом.
        
        static let noPeopleNeaby: String = "noPeopleNearby"
        // EN: Scanning is active. Nearby Telescan users will appear here.
        // RU: Сканирование активно. Пользователи Telescan поблизости появятся здесь.
        
        static let scanAlertText: String = "scanAlertText"
        // EN: Enable scanning in Settings to open the Nearby section.
        // RU: Включите сканирование в настройках, чтобы открыть раздел «Рядом».
        
    }

    // MARK: - Nearby notifications
    struct NearbyNotifications {
        static let title: String = "nearbyNotificationTitle"
        static let initialCountFormat: String =
            "nearbyNotificationInitialCountFormat"
        static let updateCountFormat: String =
            "nearbyNotificationUpdateCountFormat"
    }

    // MARK: - Nearby profile moderation
    struct NearbyProfile {
        static let close: String = "nearbyProfileClose"
        static let actions: String = "nearbyProfileActions"
        static let usernameFallback: String = "nearbyProfileUsernameFallback"
        static let message: String = "nearbyProfileMessage"
        static let report: String = "nearbyProfileReport"
        static let block: String = "nearbyProfileBlock"

        static let reportTitle: String = "nearbyProfileReportTitle"
        static let reportMessage: String = "nearbyProfileReportMessage"
        static let reportSpam: String = "nearbyProfileReportSpam"
        static let reportHarassment: String = "nearbyProfileReportHarassment"
        static let reportInappropriate: String = "nearbyProfileReportInappropriate"
        static let reportImpersonation: String = "nearbyProfileReportImpersonation"
        static let reportOther: String = "nearbyProfileReportOther"
        static let reportConfirmTitle: String = "nearbyProfileReportConfirmTitle"
        static let reportConfirmMessage: String = "nearbyProfileReportConfirmMessage"
        static let reportDetailsPlaceholder: String =
            "nearbyProfileReportDetailsPlaceholder"
        static let reportSend: String = "nearbyProfileReportSend"
        static let reportSentTitle: String = "nearbyProfileReportSentTitle"
        static let reportSentMessage: String = "nearbyProfileReportSentMessage"

        static let blockTitle: String = "nearbyProfileBlockTitle"
        static let blockMessage: String = "nearbyProfileBlockMessage"
        static let blockConfirm: String = "nearbyProfileBlockConfirm"
        static let blockedMenu: String = "nearbyProfileBlockedMenu"
        static let blockedProfiles: String = "nearbyProfileBlockedProfiles"
        static let noBlockedProfiles: String = "nearbyProfileNoBlockedProfiles"
        static let unblock: String = "nearbyProfileUnblock"

        static let actionFailedTitle: String = "nearbyProfileActionFailedTitle"
        static let actionFailedMessage: String = "nearbyProfileActionFailedMessage"
        static let acknowledge: String = "nearbyProfileAcknowledge"
    }
    
    // MARK: - Profile
    struct Profile {
        static let telescanBot: String = "Telescan_bot"
        
        static let photoOptions: String = "photoOptions"
        // EN: Photo Options
        // RU: Настройки фото
        
        static let takePhoto: String = "takePhoto"
        // EN: Take Photo
        // RU: Сделать фото
        
        static let galleryPhoto: String = "galleryPhoto"
        // EN: Choose from Gallery
        // RU: Выбрать из галереи
        
        static let deletePhoto: String = "deletePhoto"
        // EN: Delete Photo
        // RU: Удалить фото
        
        static let shareUtg: String = "shareUtg"
        // EN: Share your profile
        // RU: Поделиться профилем
        
        static let creatorCredit: String = "creatorCredit"
        // EN/RU: from Ruslan Chukavin

        static let moreActions: String = "profileMoreActions"
        static let myCard: String = "profileMyCard"

        static let developerLinksTitle: String = "developerLinksTitle"
        static let developerLinksMessage: String = "developerLinksMessage"
        static let telegramChannel: String = "telegramChannel"

        static let bioTitle: String = "profileBioTitle"
        static let bioPlaceholder: String = "profileBioPlaceholder"
        static let bioEmpty: String = "profileBioEmpty"
        static let bioApply: String = "profileBioApply"
        static let bioSaveFailed: String = "profileBioSaveFailed"

        static let logout: String = "logout"
        static let accountActionsTitle: String = "accountActionsTitle"
        static let logoutCurrent: String = "logoutCurrent"
        static let logoutCurrentTitle: String = "logoutCurrentTitle"
        static let logoutCurrentMessage: String = "logoutCurrentMessage"
        static let logoutFailed: String = "logoutFailed"

        static let deleteAccount: String = "deleteAccount"
        static let deleteAccountTitle: String = "deleteAccountTitle"
        static let deleteAccountMessage: String = "deleteAccountMessage"
        static let deleteAccountFailed: String = "deleteAccountFailed"
        static let deleteAccountFailedMessage: String = "deleteAccountFailedMessage"
    }
    
    struct Info {
        static let title = "info_title"

        static let whyTelescan = "info_why_telescan"
        static let howItWorks = "info_how_it_works"
        static let howItWorksDescription = "info_how_it_works_description"
        
        static let version = "version"
        // EN: Version
        // RU: Версия
        
        static let copyUsername = "copyUsername"
        // EN: Copy and paste into Telegram search
        // RU: Скопируйте и вставьте в поле поиска Telegram
        
        static let proprietaryLicense = "proprietaryLicense"
        // EN: Copyright © 2021 - 2026 Ruslan Chukavin. All rights reserved.
        // RU: © 2021 - 2026 Ruslan Chukavin. Все права защищены.

        static let story = "info_story"

        static let rulesAndPrivacy = "rulesAndPrivacy"
        static let aboutApp = "info_about_app"
        static let publicProject = "info_public_project"
        static let questionsAndSuggestions = "info_questions_and_suggestions"
        
        static let currentVersion = "1.0.0"
    }
}

struct IncLogos {
    static let shareplay = "shareplay"
    static let personFillViewwfinder = "person.fill.viewfinder"
}

struct Links {
    
    static let telescanBot = AppConfig.telescanBot
    static let local = AppConfig.localHost
    static let origin = AppConfig.apiOrigin
    
    static let apiV1 = origin + "/api/v1"
    static let privacyPolicy = "https://tgtelescan.ru/privacy"
    static let termsOfService = "https://tgtelescan.ru/terms"
}

enum SelectedTab: Int {
    case near = 0
    case profile = 1
    case met = 2
}

enum Keys: String {
    case telescanIDKey = "telescan_id"
    case tgNameKey = "tgName"
    case usernameKey = "username"
    case bioKey = "bio"
    case photoS3URLKey = "photoS3Url"
    case isScaning = "isScaning"
    case isReg = "isReg"
}

enum HTTPStatus: Int {
    case okey = 200
    case created = 201
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case serverError = 500
}

enum HTTPMethods: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}
