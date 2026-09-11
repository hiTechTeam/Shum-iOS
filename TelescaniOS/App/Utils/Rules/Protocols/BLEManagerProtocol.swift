import Foundation

enum BLEPresencePolicy {
    static let activeTimeout: TimeInterval = 60
    static let backgroundTimeout: TimeInterval = 60
    static let signalLossIndicatorDelay: TimeInterval = 3
    static let countdownUpdateInterval: TimeInterval = 1
    static let cleanupInterval: TimeInterval = 1
}

public protocol BLEManagerDelegate: AnyObject {
    func didDiscoverDevice(id: String, rssi: Int, epoch: UUID)
    func didUpdateDevice(id: String, rssi: Int, epoch: UUID)
    func didLoseDevice(id: String, epoch: UUID)
    func didFail(with error: Error, epoch: UUID)
    func didReceiveProfile(id: String, epoch: UUID)
}

extension BLEManagerDelegate {
    public func didReceiveProfile(id: String, epoch: UUID) { }
}

protocol BLEManagerProtocol: AnyObject {
    
    var delegate: BLEManagerDelegate? { get set }
    
    // SCAN
    func startScanning()
    func restartScanning()
    func stopScanning()

    // ADVERTISE
    func startAdvertising(id: String)
    func restartAdvertising(id: String)
    func stopAdvertising()

    func reconcileDiscoveryState()
    func setApplicationActive(_ isActive: Bool)
    /// Synchronously changes the account/scan epoch used by source callbacks.
    func setDiscoveryEventEpoch(_ epoch: UUID?)

    func reset()
    
    var isBluetoothAvailable: Bool { get }
}
