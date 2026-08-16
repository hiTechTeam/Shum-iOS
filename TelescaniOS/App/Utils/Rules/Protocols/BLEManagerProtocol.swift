import Foundation

enum BLEPresencePolicy {
    static let activeTimeout: TimeInterval = 10
    static let backgroundTimeout: TimeInterval = 45
    static let signalLossIndicatorDelay: TimeInterval = 3
    static let countdownUpdateInterval: TimeInterval = 1
    static let cleanupInterval: TimeInterval = 1
}

public protocol BLEManagerDelegate: AnyObject {
    func didDiscoverDevice(id: String, rssi: Int)
    func didUpdateDevice(id: String, rssi: Int)
    func didLoseDevice(id: String)
    func didFail(with error: Error)
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

    func reset()
    
    var isBluetoothAvailable: Bool { get }
}
