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

    private let compactIdentityCharacteristicUUID = CBUUID(
        string: "A6B50003-8A5D-4F7A-9E4C-123456789003"
    )

    private let centralRestoreIdentifier =
        "com.telescan.ble.central"

    private let peripheralRestoreIdentifier =
        "com.telescan.ble.peripheral"

    private let storedIdentityKey =
        "com.telescan.ble.identity"

    private let discoveryEnabledKey = Keys.isScaning.rawValue

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!

    private var identityCharacteristic: CBMutableCharacteristic?
    private var compactIdentityCharacteristic: CBMutableCharacteristic?
    private var publishedService: CBMutableService?

    private var shouldScan = false
    private var shouldAdvertise = false
    private var serviceIsPublished = false

    private var currentIdentity: String?

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralRSSI: [UUID: Int] = [:]
    private var peripheralIdentities: [UUID: String] = [:]
    private var peripheralIdentityValidatedAt: [UUID: Date] = [:]
    private var identityResolutionFailures: [UUID: Int] = [:]
    private var resolvingPeripheralIDs: Set<UUID> = []
    private var retryNotBefore: [UUID: Date] = [:]
    private var devicesLastSeen: [String: Date] = [:]

    private let activeDeviceTimeout: TimeInterval = 10
    private let backgroundDeviceTimeout: TimeInterval = 45
    private let identityResolutionTimeout: TimeInterval = 8
    private let identityRetryDelay: TimeInterval = 3
    private let identityRevalidationInterval: TimeInterval = 30
    private var isApplicationActive = true
    private var cleanupTimer: DispatchSourceTimer?

    public var isBluetoothAvailable: Bool {
        centralManager.state == .poweredOn &&
        peripheralManager.state == .poweredOn
    }

    private override init() {
        super.init()

        logger.info("BLEManager init")

        if let storedIdentity = UserDefaults.standard.string(
            forKey: storedIdentityKey
        ), let uuid = UUID(uuidString: storedIdentity) {
            currentIdentity = uuid.uuidString.lowercased()
        } else {
            currentIdentity = nil
        }

        let discoveryEnabled = UserDefaults.standard.bool(
            forKey: discoveryEnabledKey
        )
        shouldScan = discoveryEnabled
        shouldAdvertise = discoveryEnabled && currentIdentity != nil

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

    public func restartScanning() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldScan = true
            self.centralManager.stopScan()
            self.cancelIdentityResolutions()
            self.clearPresence(notify: true)

            self.queue.asyncAfter(deadline: .now() + 0.2) {
                self.startScanningIfPossible()
            }
        }
    }

    public func stopScanning() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldScan = false

            self.stopScanningNow(clearPresence: true)

            self.logger.info("Scanning stopped")
        }
    }

    public func startAdvertising(id: String) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let identity = UUID(uuidString: id) else {
                self.logger.error("Advertising identity is not a UUID")
                return
            }

            self.logger.info("startAdvertising called")

            self.currentIdentity = identity.uuidString.lowercased()
            self.shouldAdvertise = true

            UserDefaults.standard.set(
                self.currentIdentity,
                forKey: self.storedIdentityKey
            )

            self.publishServiceIfPossible()
        }
    }

    public func restartAdvertising(id: String) {
        queue.async { [weak self] in
            guard let self else { return }

            guard let identity = UUID(uuidString: id) else {
                self.logger.error("Advertising identity is not a UUID")
                return
            }

            self.logger.info("restartAdvertising called")

            self.currentIdentity = identity.uuidString.lowercased()
            self.shouldAdvertise = UserDefaults.standard.bool(
                forKey: self.discoveryEnabledKey
            )

            UserDefaults.standard.set(
                self.currentIdentity,
                forKey: self.storedIdentityKey
            )

            self.peripheralManager.stopAdvertising()
            self.peripheralManager.removeAllServices()

            self.identityCharacteristic = nil
            self.compactIdentityCharacteristic = nil
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
            self.peripheralManager.removeAllServices()
            self.identityCharacteristic = nil
            self.compactIdentityCharacteristic = nil
            self.publishedService = nil
            self.serviceIsPublished = false

            self.logger.info("Advertising stopped")
        }
    }

    public func reconcileDiscoveryState() {
        queue.async { [weak self] in
            self?.reconcileWithPersistedState()
        }
    }

    public func setApplicationActive(_ isActive: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isApplicationActive = isActive
            if isActive {
                self.reconcileWithPersistedState()
                self.removeExpiredDevices()
            }
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
            self.peripheralIdentities.removeAll()
            self.peripheralIdentityValidatedAt.removeAll()
            self.identityResolutionFailures.removeAll()
            self.resolvingPeripheralIDs.removeAll()
            self.retryNotBefore.removeAll()
            self.devicesLastSeen.removeAll()

            self.identityCharacteristic = nil
            self.compactIdentityCharacteristic = nil
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

    private func stopScanningNow(clearPresence shouldClearPresence: Bool) {
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        cancelIdentityResolutions()
        if shouldClearPresence {
            clearPresence(notify: true)
        }
    }

    private func reconcileWithPersistedState() {
        let enabled = UserDefaults.standard.bool(
            forKey: discoveryEnabledKey
        )
        shouldScan = enabled
        shouldAdvertise = enabled && currentIdentity != nil

        if enabled {
            startScanningIfPossible()
            publishServiceIfPossible()
        } else {
            stopScanningNow(clearPresence: true)
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            identityCharacteristic = nil
            compactIdentityCharacteristic = nil
            publishedService = nil
            serviceIsPublished = false
        }
    }

    private func publishServiceIfPossible() {
        guard shouldAdvertise else { return }

        guard peripheralManager.state == .poweredOn else {
            logger.info(
                "Advertising waiting for Bluetooth, state: \(peripheralManager.state.rawValue)"
            )
            return
        }

        guard let identity = currentIdentity.flatMap(UUID.init(uuidString:)),
              let compactIdentityData = Self.encodedIdentity(identity),
              let legacyIdentityData = identity.uuidString.lowercased()
                .data(using: .utf8) else {
            logger.error("Advertising identity is empty")
            return
        }

        if serviceIsPublished {
            identityCharacteristic?.value = legacyIdentityData
            compactIdentityCharacteristic?.value = compactIdentityData
            startAdvertisingIfPossible()
            return
        }

        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()

        let characteristic = CBMutableCharacteristic(
            type: identityCharacteristicUUID,
            properties: [.read],
            value: legacyIdentityData,
            permissions: [.readable]
        )

        let compactCharacteristic = CBMutableCharacteristic(
            type: compactIdentityCharacteristicUUID,
            properties: [.read],
            value: compactIdentityData,
            permissions: [.readable]
        )

        let service = CBMutableService(
            type: serviceUUID,
            primary: true
        )

        service.characteristics = [
            compactCharacteristic,
            characteristic
        ]

        identityCharacteristic = characteristic
        compactIdentityCharacteristic = compactCharacteristic
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
            logger.info("Advertising is already active")
            return
        }

        let advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]

        peripheralManager.startAdvertising(advertisement)

        logger.info("Advertising requested")
    }

    private func handleIdentity(
        _ identity: String,
        rssi: Int,
        peripheralID: UUID,
        wasValidated: Bool = true
    ) {
        guard shouldScan else { return }
        guard let uuid = UUID(uuidString: identity) else { return }
        let canonicalIdentity = uuid.uuidString.lowercased()
        var replacedIdentity: String?
        if wasValidated {
            if let previousIdentity = peripheralIdentities[peripheralID],
               previousIdentity != canonicalIdentity {
                devicesLastSeen.removeValue(forKey: previousIdentity)
                replacedIdentity = previousIdentity
            }
            peripheralIdentities[peripheralID] = canonicalIdentity
            peripheralIdentityValidatedAt[peripheralID] = Date()
            retryNotBefore.removeValue(forKey: peripheralID)
        }
        if let replacedIdentity {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didLoseDevice(id: replacedIdentity)
            }
        }
        guard canonicalIdentity != currentIdentity else { return }

        let isNewDevice = devicesLastSeen[canonicalIdentity] == nil
        devicesLastSeen[canonicalIdentity] = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if isNewDevice {
                self.delegate?.didDiscoverDevice(
                    id: canonicalIdentity,
                    rssi: rssi
                )
            } else {
                self.delegate?.didUpdateDevice(
                    id: canonicalIdentity,
                    rssi: rssi
                )
            }

            self.logger.info("Telescan device identity received")
        }
    }

    private func connectAndReadIdentity(
        peripheral: CBPeripheral,
        rssi: Int
    ) {
        let peripheralID = peripheral.identifier
        guard !resolvingPeripheralIDs.contains(peripheralID) else {
            peripheralRSSI[peripheralID] = rssi
            return
        }
        if let retryDate = retryNotBefore[peripheralID], retryDate > Date() {
            return
        }

        resolvingPeripheralIDs.insert(peripheralID)
        discoveredPeripherals[peripheral.identifier] = peripheral
        peripheralRSSI[peripheral.identifier] = rssi
        peripheral.delegate = self

        queue.asyncAfter(deadline: .now() + identityResolutionTimeout) {
            [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.resolvingPeripheralIDs.contains(peripheralID) else {
                return
            }
            self.finishIdentityResolution(peripheral, shouldRetry: true)
        }

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
            deadline: .now() + 2,
            repeating: 2
        )

        timer.setEventHandler { [weak self] in
            self?.removeExpiredDevices()
        }

        timer.resume()
        cleanupTimer = timer
    }

    private func removeExpiredDevices() {
        let now = Date()
        let timeout = isApplicationActive
            ? activeDeviceTimeout
            : backgroundDeviceTimeout

        let expiredIDs = devicesLastSeen.compactMap {
            identity, lastSeen -> String? in

            now.timeIntervalSince(lastSeen) > timeout
                ? identity
                : nil
        }

        for identity in expiredIDs {
            devicesLastSeen.removeValue(forKey: identity)

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didLoseDevice(id: identity)
                self?.logger.info("Telescan device lost")
            }
        }
    }

    private func cancelIdentityResolutions() {
        for peripheral in discoveredPeripherals.values {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        discoveredPeripherals.removeAll()
        peripheralRSSI.removeAll()
        resolvingPeripheralIDs.removeAll()
        retryNotBefore.removeAll()
        identityResolutionFailures.removeAll()
    }

    private func finishIdentityResolution(
        _ peripheral: CBPeripheral,
        shouldRetry: Bool
    ) {
        let id = peripheral.identifier
        resolvingPeripheralIDs.remove(id)
        discoveredPeripherals.removeValue(forKey: id)
        peripheralRSSI.removeValue(forKey: id)
        if shouldRetry {
            identityResolutionFailures[id, default: 0] += 1
            if identityResolutionFailures[id, default: 0] >= 3 {
                peripheralIdentities.removeValue(forKey: id)
                peripheralIdentityValidatedAt.removeValue(forKey: id)
                identityResolutionFailures.removeValue(forKey: id)
            }
            retryNotBefore[id] = Date().addingTimeInterval(identityRetryDelay)
        } else {
            retryNotBefore.removeValue(forKey: id)
            identityResolutionFailures.removeValue(forKey: id)
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func clearPresence(notify: Bool) {
        let identities = Array(devicesLastSeen.keys)
        devicesLastSeen.removeAll()
        guard notify, !identities.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for identity in identities {
                self.delegate?.didLoseDevice(id: identity)
            }
        }
    }

    static func encodedIdentity(_ identity: UUID) -> Data? {
        var bytes = identity.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    static func decodedIdentity(_ data: Data) -> UUID? {
        if data.count == 16 {
            let bytes = [UInt8](data)
            return bytes.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return nil }
                return NSUUID(uuidBytes: baseAddress) as UUID
            }
        }
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
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
            stopScanningNow(clearPresence: true)
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
        guard shouldScan else { return }
        let rssi = RSSI.intValue

        logger.debug(
            "Discovered peripheral=\(peripheral.identifier), rssi=\(rssi), advertisement=\(advertisementData)"
        )

        if let knownIdentity = peripheralIdentities[peripheral.identifier] {
            handleIdentity(
                knownIdentity,
                rssi: rssi,
                peripheralID: peripheral.identifier,
                wasValidated: false
            )
            if let validationDate = peripheralIdentityValidatedAt[
                    peripheral.identifier
               ], Date().timeIntervalSince(validationDate)
                    < identityRevalidationInterval {
                return
            }
        }

        if let advertisedIdentity =
            advertisementData[CBAdvertisementDataLocalNameKey]
                as? String,
           let identity = UUID(uuidString: advertisedIdentity) {

            handleIdentity(
                identity.uuidString,
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

        guard shouldScan,
              resolvingPeripheralIDs.contains(peripheral.identifier) else {
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
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
        finishIdentityResolution(peripheral, shouldRetry: true)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        logger.info(
            "Disconnected peripheral: \(peripheral.identifier)"
        )

        let id = peripheral.identifier
        if resolvingPeripheralIDs.contains(id) {
            finishIdentityResolution(peripheral, shouldRetry: true)
        } else {
            discoveredPeripherals.removeValue(forKey: id)
            peripheralRSSI.removeValue(forKey: id)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        logger.info("Restoring central state")

        shouldScan = UserDefaults.standard.bool(
            forKey: discoveryEnabledKey
        )

        if let peripherals =
            dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral] {

            for peripheral in peripherals {
                discoveredPeripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self

                if shouldScan, peripheral.state == .connected {
                    connectAndReadIdentity(peripheral: peripheral, rssi: -100)
                }
            }
        }

        if shouldScan {
            startScanningIfPossible()
        } else {
            stopScanningNow(clearPresence: true)
        }
    }
}

extension BLEManager: CBPeripheralDelegate {

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard shouldScan,
              resolvingPeripheralIDs.contains(peripheral.identifier) else {
            finishIdentityResolution(peripheral, shouldRetry: false)
            return
        }
        if let error {
            logger.warning(
                "Service discovery failed: \(error.localizedDescription)"
            )

            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        guard let service = peripheral.services?.first(
            where: { $0.uuid == serviceUUID }
        ) else {
            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        peripheral.discoverCharacteristics(
            [
                compactIdentityCharacteristicUUID,
                identityCharacteristicUUID
            ],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard shouldScan,
              resolvingPeripheralIDs.contains(peripheral.identifier) else {
            finishIdentityResolution(peripheral, shouldRetry: false)
            return
        }
        if let error {
            logger.warning(
                "Characteristic discovery failed: \(error.localizedDescription)"
            )

            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        guard let characteristic = service.characteristics?.first(
            where: { $0.uuid == compactIdentityCharacteristicUUID }
        ) ?? service.characteristics?.first(
            where: { $0.uuid == identityCharacteristicUUID }
        ) else {
            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        peripheral.readValue(for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldScan,
              resolvingPeripheralIDs.contains(peripheral.identifier) else {
            finishIdentityResolution(peripheral, shouldRetry: false)
            return
        }
        if let error {
            logger.warning(
                "Identity read failed: \(error.localizedDescription)"
            )
            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        guard characteristic.uuid == compactIdentityCharacteristicUUID
                || characteristic.uuid == identityCharacteristicUUID,
              let data = characteristic.value,
              let identity = Self.decodedIdentity(data) else {
            logger.warning("Invalid BLE identity value")
            finishIdentityResolution(peripheral, shouldRetry: true)
            return
        }

        let rssi = peripheralRSSI[peripheral.identifier] ?? -100

        handleIdentity(
            identity.uuidString,
            rssi: rssi,
            peripheralID: peripheral.identifier
        )
        finishIdentityResolution(peripheral, shouldRetry: false)
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
            reconcileWithPersistedState()

        case .poweredOff,
             .unauthorized,
             .unsupported,
             .resetting,
             .unknown:
            serviceIsPublished = false
            peripheralManager.stopAdvertising()
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

        guard shouldAdvertise else {
            peripheralManager.removeAllServices()
            identityCharacteristic = nil
            compactIdentityCharacteristic = nil
            publishedService = nil
            serviceIsPublished = false
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

        shouldAdvertise = UserDefaults.standard.bool(
            forKey: discoveryEnabledKey
        ) && currentIdentity != nil

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
            compactIdentityCharacteristic =
                restoredService.characteristics?.first(
                    where: {
                        $0.uuid == compactIdentityCharacteristicUUID
                    }
                ) as? CBMutableCharacteristic

            serviceIsPublished = true
        }

        if shouldAdvertise {
            publishServiceIfPossible()
        } else {
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            identityCharacteristic = nil
            compactIdentityCharacteristic = nil
            publishedService = nil
            serviceIsPublished = false
        }
    }
}
