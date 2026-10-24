import CoreBluetooth
import Foundation
import ShumCore

/// Shum-Core's session object. It locks itself (a mutex in Rust), so it can
/// be used from the core queue while the main thread holds this reference.
private struct CoreHandle: @unchecked Sendable {
    let session: MobileSession
}

/// The profile session of Shum-Core, the core every Shum client shares (the
/// CLI, the desktop app, the browser and this app). Shum-Core decides what to
/// store, send and answer; this class keeps the relay WebSockets, the clock
/// and push requests, and carries out Shum-Core's effects in order.
///
/// Shum-Core works on its own serial queue, as it does on its own thread in
/// the other clients: every call checks and stores the whole profile, which
/// must never hold up typing or animations on the main thread.
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
    private let queue = DispatchQueue(label: "shum.core", qos: .userInitiated)
    private let push: URL?
    private var sockets: [UInt32: ShumRelaySocket] = [:]
    private var timer: Timer?
    private var waiting: [UInt64: (Result<Any, Error>) -> Void] = [:]
    private var lastID: UInt64 = 0
    /// Shum-Core's commit count when screens last read its state.
    private var shownRevision: UInt64 = 0
    /// A snapshot-only refresh is due within half a second.
    private var refreshDue = false
    /// Called with true after Shum-Core stored something, so screens read its
    /// state again; with false when only the snapshot changed: people nearby,
    /// typing, "in chat" or relays.
    var changed: ((Bool) -> Void)?
    /// A renamed profile, for the local profile list.
    var renamed: ((String) -> Void)?
    /// Shum-Core's Bluetooth mesh on this phone's radio, while it runs.
    private var radio: ShumCoreRadio?
    /// Whether Bluetooth is on, while Shum-Core's radio runs.
    var radioPower: ((CBManagerState) -> Void)?

    nonisolated static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

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
        stopRadio()
        timer?.invalidate()
        timer = nil
        sockets.values.forEach { $0.close() }
        sockets.removeAll()
    }

    /// The whole profile as Shum-Core shows it to every client.
    func snapshot() -> [String: Any] {
        let handle = CoreHandle(session: core)
        let text = queue.sync { handle.session.snapshot() }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// The stored profile state (protocol section 09) as JSON.
    func state() -> String {
        let handle = CoreHandle(session: core)
        return queue.sync { handle.session.state() }
    }

    /// Reads the snapshot, and the stored state when `stored`, on the core
    /// queue, decodes both there and hands them to the main thread.
    func read(stored: Bool, _ done: @escaping @MainActor (Result<ShumDatabase, Error>?, [String: Any]) -> Void) {
        let handle = CoreHandle(session: core)
        queue.async {
            let state = stored ? Result { try ShumMessageStore.decodeCoreState(handle.session.state()) } : nil
            let snapshot = (try? JSONSerialization.jsonObject(with: Data(handle.session.snapshot().utf8))) as? [String: Any] ?? [:]
            let result = Unchecked((state, snapshot))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result.value.0, result.value.1) } }
        }
    }

    /// The app is back in the foreground, or a push woke it: relays
    /// reconnect at once instead of after their retry pause.
    func wake() {
        step { $0.wake(now: Self.now()) }
    }

    /// Bluetooth on: Shum-Core's mesh runs on this phone's radio, the same
    /// mesh as Shum on desktops. Its links, bytes and signal strength go to
    /// Shum-Core; the frames it returns go out on their links.
    func startRadio() {
        guard radio == nil else { return }
        let radio = ShumCoreRadio()
        radio.onEvent = { [weak self] event in
            guard let self else { return }
            let now = Self.now()
            switch event {
            case .connected(let link, let budget, let rssi):
                self.step { $0.bleConnected(link: link, budget: UInt32(budget), rssi: rssi.map(Int16.init(clamping:)), now: now) }
            case .received(let link, let bytes):
                self.step { $0.bleReceived(link: link, bytes: bytes, now: now) }
            case .disconnected(let link):
                self.step { $0.bleDisconnected(link: link) }
            case .rssi(let link, let value):
                self.step { $0.bleRssi(link: link, rssi: Int16(clamping: value), now: now) }
            case .power(let state):
                self.radioPower?(state)
            }
        }
        self.radio = radio
        step { try? $0.bleStart(now: Self.now()) }
        radio.start()
    }

    /// Bluetooth off: the radio stops and everyone nearby is gone.
    func stopRadio() {
        guard let radio else { return }
        self.radio = nil
        radio.onEvent = nil
        radio.stop()
        step { $0.bleStop() }
    }

    /// Runs a request (the same JSON commands as the CLI and the desktop app)
    /// and returns its answer.
    func request(_ request: [String: Any]) async throws -> Any {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        lastID += 1
        let id = lastID
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = { continuation.resume(with: $0) }
            run(answering: id) { $0.request(id: id, request: json, now: Self.now()) }
        }
    }

    nonisolated private static func answer(_ text: String) throws -> Any {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        guard let object = value as? [String: Any] else { throw Failure.core(text) }
        if let error = object["error"] { throw Failure.answer(error) }
        return object["ok"] ?? NSNull()
    }

    private func step(news: Bool = false, _ input: @escaping (MobileSession) -> Void) {
        run(news: news) { input($0); return nil }
    }

    /// Feeds Shum-Core on its queue, then carries out what it decided, in
    /// order, on the main thread. Screens hear about a stored change at once;
    /// about anything else at most twice a second, and not about Bluetooth
    /// frames, which come many times a second.
    private func run(news: Bool = false, answering id: UInt64? = nil, _ input: @escaping (MobileSession) -> String?) {
        let handle = CoreHandle(session: core)
        let work = Unchecked(input)
        queue.async { [weak self] in
            let core = handle.session
            let nearby = core.nearbyRevision()
            let answer = work.value(core)
            let text = core.effects(now: Self.now())
            var effects = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
            // Relay addresses are read here too, so the main thread never
            // waits for Shum-Core.
            for index in effects.indices where effects[index]["type"] as? String == "connect" {
                let relay = (effects[index]["relay"] as? NSNumber)?.uint32Value ?? 0
                effects[index]["url"] = core.url(relay: relay)
            }
            let revision = core.revision()
            let moved = core.nearbyRevision() != nearby
            let result = Unchecked(effects)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(news: news || moved, id: id, answer: answer, effects: result.value, revision: revision)
                }
            }
        }
    }

    private func finish(news: Bool, id: UInt64?, answer: String?, effects: [[String: Any]], revision: UInt64) {
        if let id, let answer, let waiter = waiting.removeValue(forKey: id) {
            waiter(Result { try Self.answer(answer) })
        }
        for effect in effects { carry(effect) }
        if revision != shownRevision {
            shownRevision = revision
            changed?(true)
            return
        }
        let shown = news || effects.contains { $0["type"] as? String != "ble-frames" }
        guard shown, !refreshDue else { return }
        refreshDue = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.refreshDue = false
            self.changed?(false)
        }
    }

    private func carry(_ effect: [String: Any]) {
        let relay = (effect["relay"] as? NSNumber)?.uint32Value ?? 0
        switch effect["type"] as? String {
        case "connect":
            let attempt = (effect["attempt"] as? NSNumber)?.uint64Value ?? 0
            sockets[relay]?.close()
            guard let url = (effect["url"] as? String).flatMap(URL.init(string:)) else {
                step { $0.closed(relay: relay, attempt: attempt, now: Self.now()) }
                return
            }
            sockets[relay] = ShumRelaySocket(url: url) { [weak self] event in
                guard let self else { return }
                switch event {
                case .opened: self.step { $0.opened(relay: relay, attempt: attempt, now: Self.now()) }
                case .text(let text): self.step(news: true) { $0.received(relay: relay, attempt: attempt, text: text, now: Self.now()) }
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
        case "ble-frames":
            if let link = effect["link"] as? String {
                let frames = (effect["frames"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
                radio?.write(link: link, frames: frames)
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
            step { $0.pushed(event: event, error: "push service is not configured") }
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

/// Carries a value that is only read on one side of a queue hop.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
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
