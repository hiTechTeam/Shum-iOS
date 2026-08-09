import Foundation
import CoreBluetooth
import Logging

public final class BLEManager: NSObject, BLEManagerProtocol {

    public static let shared = BLEManager()

    public weak var delegate: BLEManagerDelegate?

    private let logger = Logger(label: "BLEManager")

    private let queue = DispatchQueue(
        label: "com.telescan.ble.manager",
        qos: .userInitiated
    )

    private let serviceUUID = CBUUID(
        string: "A6B50001-8A5D-4F7A-9E4C-123456789001"
    )

    private let identityCharacteristicUUID = CBUUID(
        string: "A6B50002-8A5D-4F7A-9E4C-123456789002"
    )

    private let centralRestoreIdentifier =
        "com.telescan.ble.central"

    private let peripheralRestoreIdentifier =
        "com.telescan.ble.peripheral"

    private let storedIdentityKey =
        "com.telescan.ble.identity"

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    private var identityCharacteristic: CBMutableCharacteristic?
    private var publishedService: CBMutableService?

    private var shouldScan = false
    private var shouldAdvertise = false
    private var serviceIsPublished = false

    private var currentIdentity: String?

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralRSSI: [UUID: Int] = [:]
    private var devicesLastSeen: [String: Date] = [:]

    private let deviceTimeout: TimeInterval = 20
    private var cleanupTimer: DispatchSourceTimer?

    public var isBluetoothAvailable: Bool {
        centralManager.state == .poweredOn &&
        peripheralManager.state == .poweredOn
    }

    private override init() {
        super.init()

        logger.info("BLEManager init")

        currentIdentity = UserDefaults.standard.string(
            forKey: storedIdentityKey
        )

        centralManager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey:
                    centralRestoreIdentifier
            ]
        )

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: queue,
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey:
                    peripheralRestoreIdentifier
            ]
        )

        startCleanupTimer()
    }

    public func startScanning() {
        queue.async { [weak self] in
            guard let self else { return }

            self.logger.info("startScanning called")
            self.shouldScan = true
            self.startScanningIfPossible()
        }
    }

    public func stopScanning() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldScan = false

            if self.centralManager.isScanning {
                self.centralManager.stopScan()
            }

            self.logger.info("Scanning stopped")
        }
    }

    public func startAdvertising(id: String) {
        queue.async { [weak self] in
            guard let self else { return }

            self.logger.info("startAdvertising called with id: \(id)")

            self.currentIdentity = id
            self.shouldAdvertise = true

            UserDefaults.standard.set(
                id,
                forKey: self.storedIdentityKey
            )

            self.publishServiceIfPossible()
        }
    }

    public func restartAdvertising(id: String) {
        queue.async { [weak self] in
            guard let self else { return }

            self.logger.info("restartAdvertising called with id: \(id)")

            self.currentIdentity = id
            self.shouldAdvertise = true

            UserDefaults.standard.set(
                id,
                forKey: self.storedIdentityKey
            )

            self.peripheralManager.stopAdvertising()
            self.peripheralManager.removeAllServices()

            self.identityCharacteristic = nil
            self.publishedService = nil
            self.serviceIsPublished = false

            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.publishServiceIfPossible()
            }
        }
    }

    public func stopAdvertising() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldAdvertise = false
            self.peripheralManager.stopAdvertising()

            self.logger.info("Advertising stopped")
        }
    }

    public func reset() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldScan = false
            self.shouldAdvertise = false

            self.centralManager.stopScan()
            self.peripheralManager.stopAdvertising()
            self.peripheralManager.removeAllServices()

            for peripheral in self.discoveredPeripherals.values {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }

            self.discoveredPeripherals.removeAll()
            self.peripheralRSSI.removeAll()
            self.devicesLastSeen.removeAll()

            self.identityCharacteristic = nil
            self.publishedService = nil
            self.serviceIsPublished = false
            self.currentIdentity = nil

            UserDefaults.standard.removeObject(
                forKey: self.storedIdentityKey
            )

            self.logger.info("BLEManager reset complete")
        }
    }

    private func startScanningIfPossible() {
        guard shouldScan else { return }

        guard centralManager.state == .poweredOn else {
            logger.info(
                "Scanning waiting for Bluetooth, state: \(centralManager.state.rawValue)"
            )
            return
        }

        guard !centralManager.isScanning else {
            logger.info("Scanning is already active")
            return
        }

        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ]
        )

        logger.info("Scanning started")
    }

    private func publishServiceIfPossible() {
        guard shouldAdvertise else { return }

        guard peripheralManager.state == .poweredOn else {
            logger.info(
                "Advertising waiting for Bluetooth, state: \(peripheralManager.state.rawValue)"
            )
            return
        }

        guard let identity = currentIdentity,
              !identity.isEmpty,
              let identityData = identity.data(using: .utf8) else {
            logger.error("Advertising identity is empty")
            return
        }

        if serviceIsPublished {
            identityCharacteristic?.value = identityData
            startAdvertisingIfPossible()
            return
        }

        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()

        let characteristic = CBMutableCharacteristic(
            type: identityCharacteristicUUID,
            properties: [.read],
            value: identityData,
            permissions: [.readable]
        )

        let service = CBMutableService(
            type: serviceUUID,
            primary: true
        )

        service.characteristics = [characteristic]

        identityCharacteristic = characteristic
        publishedService = service
        serviceIsPublished = false

        peripheralManager.add(service)

        logger.info("Publishing BLE identity service")
    }

    private func startAdvertisingIfPossible() {
        guard shouldAdvertise,
              serviceIsPublished,
              peripheralManager.state == .poweredOn else {
            return
        }

        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }

        var advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]

        if let identity = currentIdentity {
            advertisement[CBAdvertisementDataLocalNameKey] = identity
        }

        peripheralManager.startAdvertising(advertisement)

        logger.info("Advertising requested")
    }

    private func handleIdentity(
        _ identity: String,
        rssi: Int,
        peripheralID: UUID
    ) {
        guard !identity.isEmpty else { return }
        guard identity != currentIdentity else { return }

        let isNewDevice = devicesLastSeen[identity] == nil
        devicesLastSeen[identity] = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if isNewDevice {
                self.delegate?.didDiscoverDevice(
                    id: identity,
                    rssi: rssi
                )
            } else {
                self.delegate?.didUpdateDevice(
                    id: identity,
                    rssi: rssi
                )
            }

            self.logger.info(
                "Telescan device: id=\(identity), peripheral=\(peripheralID), rssi=\(rssi)"
            )
        }
    }

    private func connectAndReadIdentity(
        peripheral: CBPeripheral,
        rssi: Int
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        peripheralRSSI[peripheral.identifier] = rssi
        peripheral.delegate = self

        switch peripheral.state {
        case .disconnected:
            centralManager.connect(
                peripheral,
                options: nil
            )

        case .connected:
            peripheral.discoverServices([serviceUUID])

        case .connecting, .disconnecting:
            break

        @unknown default:
            break
        }
    }

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)

        timer.schedule(
            deadline: .now() + 5,
            repeating: 5
        )

        timer.setEventHandler { [weak self] in
            self?.removeExpiredDevices()
        }

        timer.resume()
        cleanupTimer = timer
    }

    private func removeExpiredDevices() {
        let now = Date()

        let expiredIDs = devicesLastSeen.compactMap {
            identity, lastSeen -> String? in

            now.timeIntervalSince(lastSeen) > deviceTimeout
                ? identity
                : nil
        }

        for identity in expiredIDs {
            devicesLastSeen.removeValue(forKey: identity)

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didLoseDevice(id: identity)
                self?.logger.info("Device lost: \(identity)")
            }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(
        _ central: CBCentralManager
    ) {
        logger.info(
            "Central state changed: \(central.state.rawValue)"
        )

        switch central.state {
        case .poweredOn:
            startScanningIfPossible()

        case .poweredOff,
             .unauthorized,
             .unsupported,
             .resetting,
             .unknown:
            logger.info("Central is unavailable")

        @unknown default:
            logger.warning("Unknown central state")
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue

        logger.debug(
            "Discovered peripheral=\(peripheral.identifier), rssi=\(rssi), advertisement=\(advertisementData)"
        )

        if let advertisedIdentity =
            advertisementData[CBAdvertisementDataLocalNameKey]
                as? String,
           !advertisedIdentity.isEmpty {

            handleIdentity(
                advertisedIdentity,
                rssi: rssi,
                peripheralID: peripheral.identifier
            )

            return
        }

        connectAndReadIdentity(
            peripheral: peripheral,
            rssi: rssi
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        logger.info(
            "Connected to peripheral: \(peripheral.identifier)"
        )

        discoveredPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.warning(
            "Failed to connect \(peripheral.identifier): \(error?.localizedDescription ?? "unknown error")"
        )

        discoveredPeripherals.removeValue(
            forKey: peripheral.identifier
        )

        peripheralRSSI.removeValue(
            forKey: peripheral.identifier
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.info(
            "Disconnected peripheral: \(peripheral.identifier)"
        )

        discoveredPeripherals.removeValue(
            forKey: peripheral.identifier
        )

        peripheralRSSI.removeValue(
            forKey: peripheral.identifier
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        logger.info("Restoring central state")

        shouldScan = true

        if let peripherals =
            dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral] {

            for peripheral in peripherals {
                discoveredPeripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self

                if peripheral.state == .connected {
                    peripheral.discoverServices([serviceUUID])
                }
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            logger.warning(
                "Service discovery failed: \(error.localizedDescription)"
            )

            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        guard let service = peripheral.services?.first(
            where: { $0.uuid == serviceUUID }
        ) else {
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        peripheral.discoverCharacteristics(
            [identityCharacteristicUUID],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            logger.warning(
                "Characteristic discovery failed: \(error.localizedDescription)"
            )

            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        guard let characteristic =
            service.characteristics?.first(
                where: {
                    $0.uuid == identityCharacteristicUUID
                }
            ) else {
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        peripheral.readValue(for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        defer {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        if let error {
            logger.warning(
                "Identity read failed: \(error.localizedDescription)"
            )
            return
        }

        guard characteristic.uuid == identityCharacteristicUUID,
              let data = characteristic.value,
              let identity = String(
                data: data,
                encoding: .utf8
              ),
              !identity.isEmpty else {
            logger.warning("Invalid BLE identity value")
            return
        }

        let rssi = peripheralRSSI[peripheral.identifier] ?? -100

        handleIdentity(
            identity,
            rssi: rssi,
            peripheralID: peripheral.identifier
        )
    }
}

extension BLEManager: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(
        _ peripheral: CBPeripheralManager
    ) {
        logger.info(
            "Peripheral state changed: \(peripheral.state.rawValue)"
        )

        switch peripheral.state {
        case .poweredOn:
            publishServiceIfPossible()

        case .poweredOff,
             .unauthorized,
             .unsupported,
             .resetting,
             .unknown:
            serviceIsPublished = false
            logger.info("Peripheral is unavailable")

        @unknown default:
            logger.warning("Unknown peripheral state")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        if let error {
            serviceIsPublished = false

            logger.error(
                "Failed to publish service: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didFail(with: error)
            }

            return
        }

        serviceIsPublished = true
        logger.info("BLE identity service published")

        startAdvertisingIfPossible()
    }

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        if let error {
            logger.error(
                "Advertising failed: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didFail(with: error)
            }

            return
        }

        logger.info("Advertising started successfully")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        willRestoreState dict: [String: Any]
    ) {
        logger.info("Restoring peripheral state")

        shouldAdvertise = currentIdentity != nil

        if let services =
            dict[CBPeripheralManagerRestoredStateServicesKey]
                as? [CBMutableService],
           let restoredService = services.first(
                where: { $0.uuid == serviceUUID }
           ) {

            publishedService = restoredService
            identityCharacteristic =
                restoredService.characteristics?.first(
                    where: {
                        $0.uuid == identityCharacteristicUUID
                    }
                ) as? CBMutableCharacteristic

            serviceIsPublished = true
        }

        if currentIdentity != nil {
            publishServiceIfPossible()
        }
    }
}
