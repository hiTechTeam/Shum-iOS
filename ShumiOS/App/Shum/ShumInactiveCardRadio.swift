import Foundation

/// Retains the original profile view-model environment without starting a second radio.
/// Shum nearby discovery and messaging are owned exclusively by ShumChatRuntime.
final class ShumInactiveCardRadio: BLEManagerProtocol {
    weak var delegate: BLEManagerDelegate?
    var isBluetoothAvailable: Bool { false }
    func startScanning() {}
    func restartScanning() {}
    func stopScanning() {}
    func startAdvertising(id: String) {}
    func restartAdvertising(id: String) {}
    func stopAdvertising() {}
    func reconcileDiscoveryState() {}
    func setApplicationActive(_ isActive: Bool) {}
    func setDiscoveryEventEpoch(_ epoch: UUID?) {}
    func reset() {}
}
