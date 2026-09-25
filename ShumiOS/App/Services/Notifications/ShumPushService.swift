import BitLogger
import CryptoKit
import Foundation
import UIKit

enum ShumPushKind: String, Encodable {
    case message
    case invitation
}

@MainActor
final class ShumPushService {
    static let shared = ShumPushService()

    private struct APICard: Encodable {
        let version: Int
        let noiseKey: String
        let signingKey: String
        let nostrKey: String
        let name: String
        let bio: String
        let signature: String

        enum CodingKeys: String, CodingKey {
            case version
            case noiseKey = "noise_key"
            case signingKey = "signing_key"
            case nostrKey = "nostr_key"
            case name
            case bio
            case signature
        }

        init(_ card: ShumContactCard) {
            version = card.version
            noiseKey = card.noiseKey.base64URLString
            signingKey = card.signingKey.base64URLString
            nostrKey = card.nostrKey
            name = card.name
            bio = card.bio
            signature = card.signature.base64URLString
        }
    }

    private struct DeviceRequest: Encodable {
        let card: APICard
        let deviceToken: String
        let environment: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case card
            case deviceToken = "device_token"
            case environment
            case appVersion = "app_version"
        }
    }

    private struct NotificationRequest: Encodable {
        let card: APICard
        let recipientID: String
        let eventID: String
        let kind: ShumPushKind

        enum CodingKeys: String, CodingKey {
            case card
            case recipientID = "recipient_id"
            case eventID = "event_id"
            case kind
        }
    }

    private typealias Signer = (Data) -> Data?

    private let session: URLSession
    private let encoder: JSONEncoder
    private var card: ShumContactCard?
    private var signer: Signer?
    private var deviceToken: String?
    private var registrationTask: Task<Void, Never>?
    private var registeredKey: String?
    private var notifiedEvents: Set<String> = []
    private var notificationTasks: [String: Task<Void, Never>] = [:]
    private var remoteEvents: Set<String> = []
    private var backgroundWakeHandler:
        ((String, @escaping (UIBackgroundFetchResult) -> Void) -> Void)?
    private var pendingWakes:
        [(eventID: String, completion: (UIBackgroundFetchResult) -> Void)] = []
    private var pendingWakeTimeoutTask: Task<Void, Never>?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func registerForRemoteNotifications() {
        #if targetEnvironment(simulator)
        return
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func configureBackgroundWake(
        _ handler: @escaping (
            String,
            @escaping (UIBackgroundFetchResult) -> Void
        ) -> Void
    ) {
        backgroundWakeHandler = handler
        pendingWakeTimeoutTask?.cancel()
        pendingWakeTimeoutTask = nil
        let wakes = pendingWakes
        pendingWakes.removeAll()
        for wake in wakes {
            handler(wake.eventID, wake.completion)
        }
    }

    func handleRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let payload = userInfo["shum"] as? [String: Any],
              let eventID = payload["event_id"] as? String,
              !eventID.isEmpty else {
            completion(.noData)
            return
        }
        remoteEvents.insert(eventID)
        if remoteEvents.count > 1_000 {
            remoteEvents.removeAll(keepingCapacity: true)
            remoteEvents.insert(eventID)
        }
        if let backgroundWakeHandler {
            backgroundWakeHandler(eventID, completion)
            return
        }
        // A background push can arrive before SwiftUI creates the coordinator.
        // Retain it briefly so launch order does not discard the wake-up.
        if pendingWakes.count >= 16 {
            pendingWakes.removeFirst().completion(.noData)
        }
        pendingWakes.append((eventID, completion))
        guard pendingWakeTimeoutTask == nil else { return }
        pendingWakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let wakes = self.pendingWakes
            self.pendingWakes.removeAll()
            self.pendingWakeTimeoutTask = nil
            for wake in wakes { wake.completion(.noData) }
        }
    }

    func consumeRemoteEvent(_ eventID: String) -> Bool {
        remoteEvents.remove(eventID) != nil
    }

    func updateDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registeredKey = nil
        scheduleRegistration()
    }

    func configure(
        card: ShumContactCard,
        signer: @escaping (Data) -> Data?
    ) {
        self.card = card
        self.signer = signer
        registeredKey = nil
        scheduleRegistration()
    }

    func clearIdentity(_ identityID: String) {
        guard card?.id == identityID else { return }
        registrationTask?.cancel()
        registrationTask = nil
        card = nil
        signer = nil
        registeredKey = nil
        notifiedEvents.removeAll(keepingCapacity: true)
        for task in notificationTasks.values { task.cancel() }
        notificationTasks.removeAll()
    }

    func unregisterCurrentDevice() {
        registrationTask?.cancel()
        registrationTask = nil
        guard let card, let deviceToken,
              let request = signedRequest(
                path: "/v1/devices",
                method: "DELETE",
                body: DeviceRequest(
                    card: APICard(card),
                    deviceToken: deviceToken,
                    environment: environment,
                    appVersion: appVersion
                )
              ) else { return }
        Task {
            _ = try? await session.data(for: request)
        }
    }

    func notify(
        recipientID: String,
        eventID: String,
        kind: ShumPushKind
    ) {
        guard !notifiedEvents.contains(eventID), notificationTasks[eventID] == nil,
              let identityID = card?.id else { return }
        notificationTasks[eventID] = Task { [weak self] in
            guard let self else { return }
            defer { notificationTasks.removeValue(forKey: eventID) }
            for delay in [UInt64(0), 2, 5, 15, 30, 60] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
                guard !Task.isCancelled, let card, card.id == identityID,
                      let request = signedRequest(
                        path: "/v1/notifications",
                        method: "POST",
                        body: NotificationRequest(
                            card: APICard(card),
                            recipientID: recipientID,
                            eventID: eventID,
                            kind: kind
                        )
                      ) else { return }
                do {
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }
                    if (200..<300).contains(http.statusCode) {
                        notifiedEvents.insert(eventID)
                        if notifiedEvents.count > 1_000 {
                            notifiedEvents.removeAll(keepingCapacity: true)
                            notifiedEvents.insert(eventID)
                        }
                        return
                    }
                    if (400..<500).contains(http.statusCode), http.statusCode != 429 {
                        SecureLogger.warning(
                            "Push notification rejected with HTTP \(http.statusCode)",
                            category: .session
                        )
                        return
                    }
                } catch {
                    // A temporary network failure must not permanently suppress
                    // the notification after the relay accepted the message.
                }
            }
            SecureLogger.warning("Push notification retries exhausted", category: .session)
        }
    }

    private func scheduleRegistration() {
        registrationTask?.cancel()
        guard let card, let deviceToken else { return }
        let key = "\(card.id):\(deviceToken):\(environment)"
        guard registeredKey != key else { return }
        registrationTask = Task { [weak self] in
            guard let self else { return }
            for delay in [UInt64(0), 15, 60, 300] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
                guard !Task.isCancelled else { return }
                if await register(card: card, deviceToken: deviceToken) {
                    registeredKey = key
                    return
                }
            }
        }
    }

    private func register(card: ShumContactCard, deviceToken: String) async -> Bool {
        guard let request = signedRequest(
            path: "/v1/devices",
            method: "POST",
            body: DeviceRequest(
                card: APICard(card),
                deviceToken: deviceToken,
                environment: environment,
                appVersion: appVersion
            )
        ) else { return false }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if !(200..<300).contains(http.statusCode) {
                SecureLogger.warning(
                    "Push registration rejected with HTTP \(http.statusCode)",
                    category: .session
                )
            }
            return (200..<300).contains(http.statusCode)
        } catch {
            SecureLogger.warning("Push registration request failed", category: .session)
            return false
        }
    }

    private func signedRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) -> URLRequest? {
        guard let baseURL, let signer,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              let bodyData = try? encoder.encode(body) else { return nil }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: bodyData)
            .map { String(format: "%02x", $0) }
            .joined()
        let canonical = Data(
            "SHUM1\n\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(digest)".utf8
        )
        guard let signature = signer(canonical),
              let signingKey = card?.signingKey else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signingKey.base64URLString, forHTTPHeaderField: "X-Shum-Public-Key")
        request.setValue(timestamp, forHTTPHeaderField: "X-Shum-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Shum-Nonce")
        request.setValue(signature.base64URLString, forHTTPHeaderField: "X-Shum-Signature")
        return request
    }

    private var baseURL: URL? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "ShumPushAPIBaseURL"
        ) as? String,
        !value.isEmpty,
        !value.contains("$("),
        let url = URL(string: value),
        url.scheme == "https" else { return nil }
        return url
    }

    private var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
    }
}

final class ShumApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            ShumPushService.shared.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            ShumPushService.shared.updateDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SecureLogger.warning(
            "Remote notification registration failed: \(error.localizedDescription)",
            category: .session
        )
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            ShumPushService.shared.handleRemoteNotification(
                userInfo,
                completion: completionHandler
            )
        }
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
