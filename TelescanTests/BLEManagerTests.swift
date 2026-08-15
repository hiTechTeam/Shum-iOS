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

// MARK: - Mock Delegate for tests

final class MockBLEManagerDelegate: BLEManagerDelegate {
    var onDiscoverDevice: ((String, Int) -> Void)?
    var onUpdateDevice: ((String, Int) -> Void)?
    var onLoseDevice: ((String) -> Void)?
    var onFail: ((Error) -> Void)?
    func didDiscoverDevice(id: String, rssi: Int) {
        onDiscoverDevice?(id, rssi)
    }
    func didUpdateDevice(id: String, rssi: Int) {
        onUpdateDevice?(id, rssi)
    }
    func didLoseDevice(id: String) {
        onLoseDevice?(id)
    }
    func didFail(with error: Error) {
        onFail?(error)
    }
}
