import Foundation
import ShumCore

/// The profile session of Shum-Core, the core every Shum client shares (the
/// CLI, the desktop app, the browser and this app). Shum-Core decides what to
/// store, send and answer; this class keeps the relay WebSockets, the clock
/// and push requests, and carries out Shum-Core's effects in order.
@MainActor
final class ShumCoreSession {
    enum Failure: LocalizedError {
        case core(String)
        case answer(Any)
        var errorDescription: String? {
            switch self {
            case .core(let text): text
            case .answer(let failure): ((failure as? [String: Any])?["text"] as? String) ?? "\(failure)"
            }
        }
    }

    private let core: MobileSession
    private let push: URL?
    private var sockets: [UInt32: ShumRelaySocket] = [:]
    private var timer: Timer?
    private var waiting: [UInt64: (Result<Any, Error>) -> Void] = [:]
    private var lastID: UInt64 = 0
    /// Called after anything Shum-Core did, so screens can read a new snapshot.
    var changed: (() -> Void)?
    /// A renamed profile, for the local profile list.
    var renamed: ((String) -> Void)?
    /// Sends a Shum packet (its JSON bytes) over Bluetooth to a routing ID.
    var sendBle: ((String, Data) -> Void)?

    static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    init(profile: MobileProfile, keys: MobileKeys, push: URL?) throws {
        do {
            core = try MobileSession.open(profile: profile, keys: keys, now: Self.now())
        } catch {
            throw Failure.core("\(error)")
        }
        self.push = push
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step { $0.tick(now: Self.now()) } }
        }
        step { $0.tick(now: Self.now()) }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        sockets.values.forEach { $0.close() }
        sockets.removeAll()
    }

    /// The whole profile as Shum-Core shows it to every client.
    func snapshot() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(core.snapshot().utf8))) as? [String: Any] ?? [:]
    }

    /// The stored profile state (protocol section 09) as JSON.
    func state() -> String { core.state() }

    /// Someone nearby with their signed card (JSON) and Noise session key.
    func nearby(routing: String, card: String, noise: Data, distance: UInt32?, direct: Bool) {
        step { try? $0.nearbyPeer(routing: routing, card: card, noise: noise, distance: distance, direct: direct) }
    }

    /// Someone nearby went out of reach.
    func gone(routing: String) {
        step { $0.nearbyGone(routing: routing) }
    }

    /// A Shum packet (JSON bytes) from Bluetooth.
    func packet(routing: String, noise: Data, bytes: Data) {
        step { try? $0.nearbyPacket(routing: routing, noise: noise, packet: bytes) }
    }

    /// Runs a request (the same JSON commands as the CLI and the desktop app)
    /// and returns its answer.
    func request(_ request: [String: Any]) async throws -> Any {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        lastID += 1
        let id = lastID
        var immediate: String?
        step { immediate = $0.request(id: id, request: json, now: Self.now()) }
        if let immediate { return try Self.answer(immediate) }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = { continuation.resume(with: $0) }
        }
    }

    private static func answer(_ text: String) throws -> Any {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        guard let object = value as? [String: Any] else { throw Failure.core(text) }
        if let error = object["error"] { throw Failure.answer(error) }
        return object["ok"] ?? NSNull()
    }

    /// Feeds Shum-Core, then carries out what it decided.
    private func step(_ input: (MobileSession) -> Void) {
        input(core)
        let text = core.effects(now: Self.now())
        guard let effects = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
              !effects.isEmpty else { return }
        for effect in effects { carry(effect) }
        changed?()
    }

    private func carry(_ effect: [String: Any]) {
        let relay = (effect["relay"] as? NSNumber)?.uint32Value ?? 0
        switch effect["type"] as? String {
        case "connect":
            let attempt = (effect["attempt"] as? NSNumber)?.uint64Value ?? 0
            sockets[relay]?.close()
            guard let url = core.url(relay: relay).flatMap(URL.init(string:)) else {
                step { $0.closed(relay: relay, attempt: attempt, now: Self.now()) }
                return
            }
            sockets[relay] = ShumRelaySocket(url: url) { [weak self] event in
                guard let self else { return }
                switch event {
                case .opened: self.step { $0.opened(relay: relay, attempt: attempt, now: Self.now()) }
                case .text(let text): self.step { $0.received(relay: relay, attempt: attempt, text: text, now: Self.now()) }
                case .closed:
                    self.sockets[relay] = nil
                    self.step { $0.closed(relay: relay, attempt: attempt, now: Self.now()) }
                }
            }
        case "send":
            sockets[relay]?.send(effect["text"] as? String ?? "")
        case "ping":
            sockets[relay]?.ping()
        case "close":
            sockets[relay]?.close()
            sockets[relay] = nil
        case "reply":
            let id = (effect["id"] as? NSNumber)?.uint64Value ?? 0
            let waiter = waiting.removeValue(forKey: id)
            if let error = effect["error"] { waiter?(.failure(Failure.answer(error))) } else { waiter?(.success(effect["ok"] ?? NSNull())) }
        case "renamed":
            if let name = effect["name"] as? String { renamed?(name) }
        case "push":
            send(push: effect)
        case "ble":
            if let peer = effect["peer"] as? String,
               let bytes = (effect["packet"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                sendBle?(peer, bytes)
            }
        default:
            // Relay news: snapshots show the connected relays.
            break
        }
    }

    /// A signed push request Shum-Core prepared (protocol section 08).
    private func send(push effect: [String: Any]) {
        let event = effect["event"] as? String ?? ""
        guard let base = push, let path = effect["path"] as? String,
              let url = URL(string: path, relativeTo: base),
              let body = (effect["body"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            core.pushed(event: event, error: "push service is not configured")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in effect["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let failure = error.map { $0.localizedDescription } ?? ((200..<300).contains(status) ? nil : "push API returned HTTP \(status)")
            Task { @MainActor in self?.step { $0.pushed(event: event, error: failure) } }
        }.resume()
    }
}

/// One relay WebSocket. It reports opening, text messages and closing.
final class ShumRelaySocket: NSObject, URLSessionWebSocketDelegate {
    enum Event { case opened, text(String), closed }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let report: @MainActor (Event) -> Void
    private var finished = false

    init(url: URL, report: @escaping @MainActor (Event) -> Void) {
        self.report = report
        super.init()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 256 * 1024
        self.session = session
        self.task = task
        task.resume()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            if error != nil { self?.finish() }
        }
    }

    func ping() {
        task?.sendPing { [weak self] error in
            if error != nil { self?.finish() }
        }
    }

    func close() {
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                DispatchQueue.main.async { MainActor.assumeIsolated { self.report(.text(text)) } }
                self.receive()
            case .success:
                // Binary frames carry nothing for Shum but show the relay is alive.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.report(.text("")) } }
                self.receive()
            case .failure:
                self.finish()
            }
        }
    }

    private func finish() {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            self.session?.invalidateAndCancel()
            MainActor.assumeIsolated { self.report(.closed) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { report(.opened) }
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}
