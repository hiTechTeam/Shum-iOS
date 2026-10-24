import CoreBluetooth
import Foundation

/// The iPhone's Bluetooth radio for Shum-Core's mesh: the same GATT service
/// and characteristic as Shum on desktops. It only moves bytes. Links,
/// handshakes, peers, frames and relaying are Shum-Core's; this class tells
/// it about links, bytes and signal strength, and writes the frames it
/// returns. As a peripheral a subscribed central is link `p:<id>`; as a
/// central a connected peripheral is link `c:<id>`.
@MainActor
final class ShumCoreRadio: NSObject {
    enum Event {
        case connected(link: String, budget: Int, rssi: Int?)
        case received(link: String, bytes: Data)
        case disconnected(link: String)
        case rssi(link: String, value: Int)
        case state(role: String, state: String)
    }

    nonisolated(unsafe) static let service = CBUUID(string: "F85FC602-7866-4F4C-90AB-4F14E107792B")
    nonisolated(unsafe) static let characteristic = CBUUID(string: "8F85918D-468D-4FBE-825A-CBD890B74D10")
    /// Shum-Core needs room for a frame header and a fragment.
    private static let minimumBudget = 107
    private static let maximumLinks = 6
    private static let maximumSubscribers = 12

    var onEvent: ((Event) -> Void)?

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var timer: Timer?

    /// Peripherals this phone connects to as a central.
    private struct Outgoing {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic?
        var ready = false
        var queue: [Data] = []
    }
    private var outgoing: [UUID: Outgoing] = [:]
    private var retryAfter: [UUID: Date] = [:]

    /// Centrals subscribed to this phone's characteristic.
    private var mutable: CBMutableCharacteristic?
    private var subscribers: [String: CBCentral] = [:]
    private var notifications: [(link: String, data: Data)] = []

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for link in outgoing.values { central?.cancelPeripheralConnection(link.peripheral) }
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        let links = outgoing.keys.map { "c:" + $0.uuidString } + Array(subscribers.keys)
        outgoing.removeAll()
        subscribers.removeAll()
        notifications.removeAll()
        central = nil
        peripheralManager = nil
        links.forEach { onEvent?(.disconnected(link: $0)) }
    }

    /// Writes frames to a link, in order.
    func write(link: String, frames: [Data]) {
        if link.hasPrefix("p:") {
            guard subscribers[link] != nil else { return }
            notifications.append(contentsOf: frames.map { (link, $0) })
            drainNotifications()
        } else if let id = UUID(uuidString: String(link.dropFirst(2))), var target = outgoing[id] {
            target.queue.append(contentsOf: frames)
            outgoing[id] = target
            drainWrites(id)
        }
    }

    /// Every five seconds: rescan for new phones and read signal strength.
    private func beat() {
        if let central, central.state == .poweredOn {
            central.stopScan()
            central.scanForPeripherals(withServices: [Self.service], options: nil)
        }
        for link in outgoing.values where link.ready { link.peripheral.readRSSI() }
    }

    private func drainWrites(_ id: UUID) {
        guard var target = outgoing[id], target.ready, let characteristic = target.characteristic else { return }
        while !target.queue.isEmpty, target.peripheral.canSendWriteWithoutResponse {
            target.peripheral.writeValue(target.queue.removeFirst(), for: characteristic, type: .withoutResponse)
        }
        outgoing[id] = target
    }

    private func drainNotifications() {
        guard let manager = peripheralManager, let mutable else { return }
        while let (link, data) = notifications.first {
            guard let subscriber = subscribers[link] else {
                notifications.removeFirst()
                continue
            }
            // false is backpressure: keep the frame until the manager is ready.
            guard manager.updateValue(data, for: mutable, onSubscribedCentrals: [subscriber]) else { return }
            notifications.removeFirst()
        }
    }

    private func lost(_ id: UUID) {
        guard let link = outgoing.removeValue(forKey: id) else { return }
        retryAfter[id] = Date().addingTimeInterval(10)
        if link.ready { onEvent?(.disconnected(link: "c:" + id.uuidString)) }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "poweredOn"
        case .poweredOff: "poweredOff"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        default: "unknown"
        }
    }
}

extension ShumCoreRadio: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            onEvent?(.state(role: "scan", state: Self.describe(central.state)))
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: [Self.service], options: nil)
            } else {
                for id in Array(outgoing.keys) { lost(id) }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard outgoing[id] == nil, outgoing.count < Self.maximumLinks,
                  retryAfter[id].map({ $0 <= Date() }) ?? true,
                  RSSI.intValue >= -95 else { return }
            peripheral.delegate = self
            outgoing[id] = Outgoing(peripheral: peripheral)
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lost(peripheral.identifier) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lost(peripheral.identifier) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            MainActor.assumeIsolated { central?.cancelPeripheralConnection(peripheral) }
            return
        }
        peripheral.discoverCharacteristics([Self.characteristic], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristic }),
                  var link = outgoing[peripheral.identifier] else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            link.characteristic = characteristic
            outgoing[peripheral.identifier] = link
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard error == nil, characteristic.isNotifying, var link = outgoing[id], !link.ready else {
                if error != nil { central?.cancelPeripheralConnection(peripheral) }
                return
            }
            let budget = min(512, peripheral.maximumWriteValueLength(for: .withoutResponse))
            guard budget >= Self.minimumBudget else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            link.ready = true
            outgoing[id] = link
            onEvent?(.connected(link: "c:" + id.uuidString, budget: budget, rssi: nil))
            peripheral.readRSSI()
            drainWrites(id)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.characteristic, let value = characteristic.value, error == nil else { return }
        MainActor.assumeIsolated {
            onEvent?(.received(link: "c:" + peripheral.identifier.uuidString, bytes: value))
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { drainWrites(peripheral.identifier) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        MainActor.assumeIsolated {
            onEvent?(.rssi(link: "c:" + peripheral.identifier.uuidString, value: RSSI.intValue))
        }
    }
}

extension ShumCoreRadio: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            onEvent?(.state(role: "advertise", state: Self.describe(peripheral.state)))
            if peripheral.state == .poweredOn {
                let value = CBMutableCharacteristic(
                    type: Self.characteristic,
                    properties: [.notify, .write, .writeWithoutResponse, .read],
                    value: nil,
                    permissions: [.readable, .writeable]
                )
                let service = CBMutableService(type: Self.service, primary: true)
                service.characteristics = [value]
                mutable = value
                peripheral.removeAllServices()
                peripheral.add(service)
            } else {
                for link in subscribers.keys { onEvent?(.disconnected(link: link)) }
                subscribers.removeAll()
                notifications.removeAll()
                mutable = nil
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                onEvent?(.state(role: "advertise", state: error.localizedDescription))
                return
            }
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service]])
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            onEvent?(.state(role: "advertise", state: error?.localizedDescription ?? "advertising"))
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.characteristic else { return }
            let link = "p:" + central.identifier.uuidString
            guard subscribers[link] == nil, subscribers.count < Self.maximumSubscribers else { return }
            let budget = min(512, central.maximumUpdateValueLength)
            guard budget >= Self.minimumBudget else { return }
            subscribers[link] = central
            onEvent?(.connected(link: link, budget: budget, rssi: nil))
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            let link = "p:" + central.identifier.uuidString
            guard subscribers.removeValue(forKey: link) != nil else { return }
            notifications.removeAll { $0.link == link }
            onEvent?(.disconnected(link: link))
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.characteristic, request.offset == 0 else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // A long-write batch arrives at once; only whole values go to Shum-Core.
        var assembled: [String: Data] = [:]
        var complete: [(String, Data)] = []
        for request in requests {
            guard request.characteristic.uuid == Self.characteristic, let value = request.value else {
                if let first = requests.first { peripheral.respond(to: first, withResult: .requestNotSupported) }
                return
            }
            let link = "p:" + request.central.identifier.uuidString
            if request.offset == 0, let prior = assembled.removeValue(forKey: link) { complete.append((link, prior)) }
            var data = assembled[link] ?? Data()
            guard request.offset == data.count, data.count + value.count <= 1_000_000 else {
                if let first = requests.first { peripheral.respond(to: first, withResult: .invalidOffset) }
                return
            }
            data.append(value)
            assembled[link] = data
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        complete.append(contentsOf: assembled.map { ($0.key, $0.value) })
        MainActor.assumeIsolated {
            for (link, bytes) in complete where subscribers[link] != nil {
                onEvent?(.received(link: link, bytes: bytes))
            }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { drainNotifications() }
    }
}
