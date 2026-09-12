import BitFoundation
import CoreBluetooth
import Foundation
import Testing
@preconcurrency @testable import Shum

struct ShumProximityTests {
    @Test func distanceRequiresBoundFreshSignalAndUsesMedian() {
        let store = BLEProximityStore()
        let peer = PeerID(str: "1111111111111111")
        let rotated = PeerID(str: "2222222222222222")
        let now = Date(timeIntervalSince1970: 1000)
        store.record(-59, peripheralID: "link", at: now)
        #expect(store.distanceMeters(for: peer, at: now) == nil)
        store.bind("link", to: peer)
        #expect(store.distanceMeters(for: peer, at: now) == 1)
        store.record(-79, peripheralID: "link", at: now)
        store.record(-79, peripheralID: "link", at: now)
        store.record(127, peripheralID: "link", at: now)
        #expect(store.distanceMeters(for: peer, at: now) == 10)
        #expect(store.distanceMeters(for: peer, at: now.addingTimeInterval(30)) == nil)
        store.bind("link", to: rotated)
        #expect(store.distanceMeters(for: peer, at: now) == nil)
        #expect(store.distanceMeters(for: rotated, at: now) == 10)
        store.remove("link")
        #expect(store.distanceMeters(for: rotated, at: now) == nil)
    }

    @Test @MainActor func runtimeHidesDistanceWhenConnectionOrBluetoothIsLost() {
        let peer = PeerID(str: "2222222222222222")
        let wire = MockTransport()
        wire.connectedPeers = [peer]
        let defaults = UserDefaults(suiteName: "ShumProximityTests.\(UUID().uuidString)")!
        let runtime = SpotchatRuntime(transport: wire, defaults: defaults)
        runtime.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOn))
        runtime.didUpdatePeerSnapshots([
            .init(peerID: peer, nickname: "Боб", isConnected: true, noisePublicKey: nil,
                  lastSeen: Date(), distanceMeters: 4)
        ])
        #expect(runtime.distanceMeters(for: peer) == 4)
        wire.connectedPeers = []
        runtime.didUpdatePeerSnapshots([])
        #expect(runtime.distanceMeters(for: peer) == nil)
        runtime.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOff))
        #expect(runtime.distanceMeters(for: peer) == nil)
    }
}
