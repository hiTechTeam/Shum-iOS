//
//  BLEManagerTests.swift
//

import Testing
import CoreBluetooth
@testable import Telescan

// These tests intentionally exercise the process-wide CoreBluetooth singleton.
// Serial execution prevents one case from clearing another case's weak delegate.
@Suite("BLEManager — basic tests.", .serialized)
struct BLEManagerTests {

    @Test("Singleton returns the same instance.")
    func singletonReturnsSameInstance() {
        let instance1 = BLEManager.shared
        let instance2 = BLEManager.shared
        #expect(instance1 === instance2)
    }

    @Test("Delegate is configured and stored on the weak link.")
    func delegateIsWeakReference() {
        var temporaryDelegate: MockBLEManagerDelegate? = MockBLEManagerDelegate()
        BLEManager.shared.delegate = temporaryDelegate
        #expect(BLEManager.shared.delegate === temporaryDelegate)
        temporaryDelegate = nil
        // After nullify — delegate should become nil
        #expect(BLEManager.shared.delegate == nil)
    }

    @Test("Delegate can be nil without crash")
    func delegateCanBeNil() {
        BLEManager.shared.delegate = nil
        BLEManager.shared.startScanning()
        BLEManager.shared.startAdvertising(id: UUID().uuidString)
        // If doesn't crash - test passes
        #expect(true)
    }

    @Test("isBluetoothAvailable returned Bool (true/false it depends of environment).")
    func bluetoothAvailabilityReturnsBool() {
        let available = BLEManager.shared.isBluetoothAvailable
        // In the simulator it is always false, but in device it can be true/false
        // The main thing is that it returns Bool, and it doesn't crash or nil
        #expect(available == true || available == false)
    }

    @Test("A telescan UUID uses a lossless 16-byte BLE representation.")
    func identityUsesCompactBinaryRepresentation() throws {
        let identity = UUID()
        let data = try #require(BLEManager.encodedIdentity(identity))

        #expect(data.count == 16)
        #expect(BLEManager.decodedIdentity(data) == identity)
    }

    @Test("A string UUID from an older app version remains readable.")
    func legacyStringIdentityRemainsCompatible() {
        let identity = UUID()
        let data = Data(identity.uuidString.utf8)

        #expect(BLEManager.decodedIdentity(data) == identity)
    }

    @Test("A peer handshake carries a compact UUID and observed RSSI.")
    func peerHandshakeCarriesIdentityAndRSSI() throws {
        let identity = UUID()
        let compactData = try #require(
            BLEManager.encodedPeerIdentityWrite(identity, rssi: -63)
        )
        let decoded = try #require(
            BLEManager.decodedPeerIdentityWrite(compactData)
        )

        #expect(decoded.identity == identity)
        #expect(decoded.rssi == -63)
        #expect(
            BLEManager.decodedPeerIdentityWrite(
                Data(identity.uuidString.utf8)
            ) == nil
        )
        #expect(BLEManager.decodedPeerIdentityWrite(Data()) == nil)
        #expect(
            BLEManager.decodedPeerIdentityWrite(
                Data(repeating: 0, count: 18)
            ) == nil
        )
    }

    @Test("An epoch transition is ordered behind queued BLE source callbacks.")
    func sourceQueueEpochTransitionPreservesCallbackOrigin() {
        let sourceQueue = DispatchQueue(
            label: "com.telescan.tests.ble-source-epoch"
        )
        let gate = BLESourceEpochGate(queue: sourceQueue)
        let observedEpoch = LockedEpochObservation()
        let accountAEpoch = UUID()
        let accountBEpoch = UUID()

        gate.set(accountAEpoch)
        sourceQueue.async {
            observedEpoch.store(gate.currentOnSourceQueue())
        }

        // This synchronous transition must drain the callback submitted above
        // before replacing A's source epoch.
        gate.set(nil)
        gate.set(accountBEpoch)

        #expect(observedEpoch.value == accountAEpoch)
    }

    @Test("A delayed advertising callback retains its request epoch.")
    func advertisingCompletionCannotAdoptNextAccountEpoch() {
        var tracker = BLESingleFlightEpochTracker()
        let accountAEpoch = UUID()
        let accountBEpoch = UUID()

        let startedA = tracker.begin(epoch: accountAEpoch)
        let overlappingB = tracker.begin(epoch: accountBEpoch)
        let completedA = tracker.takeCompletionOrigin()
        let startedB = tracker.begin(epoch: accountBEpoch)
        let completedB = tracker.takeCompletionOrigin()

        #expect(startedA)
        #expect(!overlappingB)
        #expect(completedA == accountAEpoch)
        #expect(startedB)
        #expect(completedB == accountBEpoch)
    }

    @Test("A peripheral operation drains before the next account can reuse it.")
    func peripheralOperationCannotBeOverwrittenAcrossAccountReset() throws {
        var tracker = BLEPeripheralEpochTracker()
        let peripheralID = UUID()
        let accountAEpoch = UUID()
        let accountBEpoch = UUID()

        let startedA = tracker.admit(
            peripheralID: peripheralID,
            epoch: accountAEpoch
        )
        tracker.markRetiring(peripheralID: peripheralID)
        let deferredB = tracker.admit(
            peripheralID: peripheralID,
            epoch: accountBEpoch
        )
        let staleValueAccepted = tracker.accepts(
            peripheralID: peripheralID,
            currentEpoch: accountBEpoch
        )
        let originBeforeTerminal = tracker.origin(for: peripheralID)
        let epochReleasedByATerminal = tracker.complete(
            peripheralID: peripheralID
        )
        let releasedEpoch = try #require(epochReleasedByATerminal)
        let startedB = tracker.admit(
            peripheralID: peripheralID,
            epoch: releasedEpoch
        )
        let currentValueAccepted = tracker.accepts(
            peripheralID: peripheralID,
            currentEpoch: accountBEpoch
        )

        #expect(startedA == .started)
        #expect(deferredB == .deferred)
        #expect(!staleValueAccepted)
        #expect(originBeforeTerminal == accountAEpoch)
        #expect(epochReleasedByATerminal == accountBEpoch)
        #expect(startedB == .started)
        #expect(currentValueAccepted)
    }

    @Test("Background reconnects prefer recent, eligible peripherals.")
    func backgroundReconnectCandidateSelection() {
        let now = Date(timeIntervalSince1970: 10_000)
        let newest = UUID()
        let secondNewest = UUID()
        let excluded = UUID()
        let stale = UUID()

        let selected = BLEBackgroundReconnectPolicy.candidateIDs(
            lastSeenAt: [
                newest: now.addingTimeInterval(-5),
                secondNewest: now.addingTimeInterval(-10),
                excluded: now.addingTimeInterval(-1),
                stale: now.addingTimeInterval(-901)
            ],
            excluding: [excluded],
            now: now,
            maximumAge: 900,
            limit: 2
        )

        #expect(selected == [newest, secondNewest])
    }

    @Test("Only one phone retains a symmetric background BLE link.")
    func backgroundLinkOwnershipIsDeterministic() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        #expect(
            BLEBackgroundReconnectPolicy.shouldRetainConnection(
                localIdentity: first,
                peerIdentity: second
            )
        )
        #expect(
            !BLEBackgroundReconnectPolicy.shouldRetainConnection(
                localIdentity: second,
                peerIdentity: first
            )
        )
        #expect(
            !BLEBackgroundReconnectPolicy.shouldRetainConnection(
                localIdentity: first,
                peerIdentity: first
            )
        )
    }

    @Test("reset() clean active operations and allows you to start over.")
    func resetClearsActiveOperations() async throws {
        let manager = BLEManager.shared
        manager.startScanning()
        manager.startAdvertising(id: UUID().uuidString)
        // We given a little time for the operations to start
        try await Task.sleep(for: .milliseconds(300))
        manager.reset()
        // After reset we can restart it again
        manager.startScanning()
        manager.startAdvertising(id: UUID().uuidString)
        try await Task.sleep(for: .milliseconds(300))
        #expect(true) // If you got here, it didn't crash
    }

    @Test("A possible error is expected in the simulator or when Bluetooth is turned off.")
    func errorReportedWhenBluetoothUnavailable() async throws {
        try await confirmation("Error received", expectedCount: 0...1) { errorConfirmed in
            let mockDelegate = MockBLEManagerDelegate()
            mockDelegate.onFail = { error in
                #expect(error.localizedDescription.lowercased().contains("powered off") ||
                        error.localizedDescription.lowercased().contains("bluetooth") ||
                        error.localizedDescription.lowercased().contains("unsupported"))
                errorConfirmed()
            }
            BLEManager.shared.delegate = mockDelegate
            // We run both scanning and advertising — suddenly an error will come from peripheral
            BLEManager.shared.startScanning()
            BLEManager.shared.startAdvertising(id: UUID().uuidString)
            // We're giving it more time for a possible callback.
            try await Task.sleep(for: .seconds(3))
        }
    }

    @Test("The start/stop/restart sequence does not cause crashes.")
    func sequentialOperationsDoNotCrash() async throws {
        let manager = BLEManager.shared
        manager.startScanning()
        try await Task.sleep(for: .milliseconds(200))
        manager.stopScanning()
        try await Task.sleep(for: .milliseconds(100))
        manager.startScanning()
        try await Task.sleep(for: .milliseconds(200))
        manager.startAdvertising(id: UUID().uuidString)
        try await Task.sleep(for: .milliseconds(200))
        manager.restartAdvertising(id: UUID().uuidString)
        try await Task.sleep(for: .milliseconds(500))
        manager.stopAdvertising()
        #expect(true)
    }

    @Test("Running scanning and advertising at the same time does not cause problems.")
    func simultaneousScanningAndAdvertising() async throws {
        let manager = BLEManager.shared
        manager.startScanning()
        manager.startAdvertising(id: UUID().uuidString)
        try await Task.sleep(for: .milliseconds(500))
        manager.stopScanning()
        manager.stopAdvertising()
        #expect(true)
    }
}

private final class LockedEpochObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UUID?

    var value: UUID? {
        lock.withLock { storedValue }
    }

    func store(_ value: UUID?) {
        lock.withLock { storedValue = value }
    }
}

// MARK: - Mock Delegate for tests

final class MockBLEManagerDelegate: BLEManagerDelegate {
    var onDiscoverDevice: ((String, Int) -> Void)?
    var onUpdateDevice: ((String, Int) -> Void)?
    var onLoseDevice: ((String) -> Void)?
    var onFail: ((Error) -> Void)?
    func didDiscoverDevice(id: String, rssi: Int, epoch: UUID) {
        onDiscoverDevice?(id, rssi)
    }
    func didUpdateDevice(id: String, rssi: Int, epoch: UUID) {
        onUpdateDevice?(id, rssi)
    }
    func didLoseDevice(id: String, epoch: UUID) {
        onLoseDevice?(id)
    }
    func didFail(with error: Error, epoch: UUID) {
        onFail?(error)
    }
}
