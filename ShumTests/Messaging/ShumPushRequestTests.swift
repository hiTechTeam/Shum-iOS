import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

/// Captures push relay requests instead of sending them over the network.
final class ShumPushStubProtocol: URLProtocol {
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var statuses: [Int] = []
    nonisolated(unsafe) private static var requests: [Captured] = []

    static func reset(statuses: [Int]) {
        lock.withLock { self.statuses = statuses; requests = [] }
    }

    static var captured: [Captured] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let status = Self.lock.withLock {
            Self.requests.append(Captured(request: request, body: body))
            return Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Outgoing push relay requests carry only what the privacy policy describes.
@Suite("Shum push relay requests", .serialized)
@MainActor
struct ShumPushRequestTests {
    final class Signatures { var inputs: [Data] = [] }

    private func makeService(statuses: [Int] = []) throws -> (ShumPushService, ShumContactCard, Signatures) {
        ShumPushStubProtocol.reset(statuses: statuses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShumPushStubProtocol.self]
        let service = ShumPushService(session: URLSession(configuration: configuration), baseURL: URL(string: "https://push.test")!)
        let wire = MockTransport()
        let identity = try ShumIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
        let card = try identity.card(name: "Аня", bio: "Привет")
        let signatures = Signatures()
        service.configure(card: card) { input in
            signatures.inputs.append(input)
            return Data("signature".utf8)
        }
        return (service, card, signatures)
    }

    private func waitForRequests(_ count: Int, within timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ShumPushStubProtocol.captured.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func notificationRequestIsSignedAndCarriesOnlyRoutingData() async throws {
        let (service, card, signatures) = try makeService()
        service.notify(recipientID: "recipient-id", eventID: "event-1", kind: .message)
        try await waitForRequests(1)

        let captured = try #require(ShumPushStubProtocol.captured.first)
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.url?.absoluteString == "https://push.test/v1/notifications")

        let body = try json(captured.body)
        #expect(Set(body.keys) == ["card", "recipient_id", "event_id", "kind"])
        #expect(body["recipient_id"] as? String == "recipient-id")
        #expect(body["event_id"] as? String == "event-1")
        #expect(body["kind"] as? String == "message")
        let sentCard = try #require(body["card"] as? [String: Any])
        #expect(Set(sentCard.keys) == ["version", "noise_key", "signing_key", "nostr_key", "name", "bio", "signature"])
        #expect(sentCard["name"] as? String == card.name)

        let headers = captured.request.allHTTPHeaderFields ?? [:]
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["X-Shum-Public-Key"] == base64URL(card.signingKey))
        #expect(headers["X-Shum-Signature"] == base64URL(Data("signature".utf8)))
        let timestamp = try #require(headers["X-Shum-Timestamp"])
        let nonce = try #require(headers["X-Shum-Nonce"])
        let digest = SHA256.hash(data: captured.body).map { String(format: "%02x", $0) }.joined()
        let canonical = "SHUM1\nPOST\n/v1/notifications\n\(timestamp)\n\(nonce)\n\(digest)"
        #expect(signatures.inputs.last == Data(canonical.utf8), "The signature covers method, path, time, nonce and the exact body")
        withExtendedLifetime(service) {}
    }

    @Test func deviceRegistrationSendsCardTokenAndEnvironment() async throws {
        let (service, _, _) = try makeService()
        service.updateDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))
        try await waitForRequests(1)

        let captured = try #require(ShumPushStubProtocol.captured.first)
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.url?.path == "/v1/devices")
        let body = try json(captured.body)
        #expect(Set(body.keys) == ["card", "device_token", "environment", "app_version"])
        #expect(body["device_token"] as? String == "deadbeef")
        #expect(body["environment"] as? String == "sandbox")
        withExtendedLifetime(service) {}
    }

    @Test func deliveredEventIsNotSentAgain() async throws {
        let (service, _, _) = try makeService(statuses: [200])
        service.notify(recipientID: "recipient-id", eventID: "event-once", kind: .invitation)
        try await waitForRequests(1)
        service.notify(recipientID: "recipient-id", eventID: "event-once", kind: .invitation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(ShumPushStubProtocol.captured.count == 1)
        withExtendedLifetime(service) {}
    }

    @Test func serverErrorsRetryButRejectedRequestsDoNot() async throws {
        let (retrying, _, _) = try makeService(statuses: [503, 200])
        retrying.notify(recipientID: "recipient-id", eventID: "event-retry", kind: .message)
        try await waitForRequests(2)
        #expect(ShumPushStubProtocol.captured.count == 2, "A 503 is retried")
        withExtendedLifetime(retrying) {}

        let (rejected, _, _) = try makeService(statuses: [400])
        rejected.notify(recipientID: "recipient-id", eventID: "event-rejected", kind: .message)
        try await waitForRequests(1)
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(ShumPushStubProtocol.captured.count == 1, "A 400 is not retried")
        withExtendedLifetime(rejected) {}
    }
}
