import Foundation
import CoreBluetooth
import Logging

/// Owns the discovery epoch on the same serial queue Core Bluetooth uses for
/// delegate delivery. A synchronous transition is therefore ordered after
/// every source callback already submitted to that queue.
final class BLESourceEpochGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var epoch: UUID?

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    func set(_ epoch: UUID?) {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            self.epoch = epoch
        } else {
            queue.sync {
                self.epoch = epoch
            }
        }
    }

    func currentOnSourceQueue() -> UUID? {
        dispatchPrecondition(condition: .onQueue(queue))
        return epoch
    }

    func acceptsOnSourceQueue(_ candidate: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return epoch == candidate
    }
}

struct BLESingleFlightEpochTracker {
    private var pending: UUID?

    var hasPending: Bool { pending != nil }

    mutating func begin(epoch: UUID) -> Bool {
        guard pending == nil else { return false }
        pending = epoch
        return true
    }

    mutating func takeCompletionOrigin() -> UUID? {
        defer { pending = nil }
        return pending
    }
}

struct BLEPeripheralEpochTracker {
    enum Admission: Equatable {
        case started
        case alreadyActive
        case deferred
    }

    private struct Operation {
        let epoch: UUID
        var isRetiring: Bool
    }

    private var operations: [UUID: Operation] = [:]
    private var deferredEpochs: [UUID: UUID] = [:]

    mutating func admit(peripheralID: UUID, epoch: UUID) -> Admission {
        if let operation = operations[peripheralID] {
            if operation.epoch == epoch {
                return .alreadyActive
            }
            deferredEpochs[peripheralID] = epoch
            return .deferred
        }
        operations[peripheralID] = Operation(
            epoch: epoch,
            isRetiring: false
        )
        return .started
    }

    func origin(for peripheralID: UUID) -> UUID? {
        operations[peripheralID]?.epoch
    }

    func accepts(peripheralID: UUID, currentEpoch: UUID) -> Bool {
        guard let operation = operations[peripheralID] else { return false }
        return !operation.isRetiring && operation.epoch == currentEpoch
    }

    mutating func markRetiring(peripheralID: UUID) {
        guard var operation = operations[peripheralID] else { return }
        operation.isRetiring = true
        operations[peripheralID] = operation
    }

    mutating func complete(peripheralID: UUID) -> UUID? {
        operations.removeValue(forKey: peripheralID)
        return deferredEpochs.removeValue(forKey: peripheralID)
    }

    mutating func discardDeferred() {
        deferredEpochs.removeAll()
    }
}

public final class BLEManager: NSObject, BLEManagerProtocol {

    struct PeerIdentityWrite: Equatable {
        let identity: UUID
        let rssi: Int
    }

    public static let shared = BLEManager()

    public weak var delegate: BLEManagerDelegate?

    private let logger = Logger(label: "BLEManager")

    private let queue: DispatchQueue
    private let discoveryEventEpochGate: BLESourceEpochGate

    private let serviceUUID = CBUUID(
        string: "A6B50001-8A5D-4F7A-9E4C-123456789001"
    )

    private let identityCharacteristicUUID = CBUUID(
        string: "A6B50002-8A5D-4F7A-9E4C-123456789002"
    )

    private let compactIdentityCharacteristicUUID = CBUUID(
        string: "A6B50003-8A5D-4F7A-9E4C-123456789003"
    )

    private let peerIdentityWriteCharacteristicUUID = CBUUID(
        string: "A6B50004-8A5D-4F7A-9E4C-123456789004"
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
    private var peerIdentityWriteCharacteristic: CBMutableCharacteristic?
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
    private var identityResolutionTimeoutGenerations: [UUID: Int] = [:]
    private var peripheralEpochTracker = BLEPeripheralEpochTracker()
    private var deferredPeripheralResolutions: [UUID: (
        peripheral: CBPeripheral,
        rssi: Int
    )] = [:]
    private var peripheralFinishShouldRetry: [UUID: Bool] = [:]
    private var peripheralResolutionServices: [UUID: ObjectIdentifier] = [:]
    private var peripheralReadCharacteristics: [UUID: ObjectIdentifier] = [:]
    private var peripheralWriteCharacteristics: [UUID: ObjectIdentifier] = [:]
    private var devicesLastSeen: [String: Date] = [:]
    private var servicePublicationEpochs: [ObjectIdentifier: UUID] = [:]
    private var advertisingEpochTracker = BLESingleFlightEpochTracker()

    private let foregroundIdentityResolutionTimeout: TimeInterval = 8
    private let identityRetryDelay: TimeInterval = 3
    private let identityRevalidationInterval: TimeInterval = 30
    private var isApplicationActive = false
    private var cleanupTimer: DispatchSourceTimer?

    public var isBluetoothAvailable: Bool {
        centralManager.state == .poweredOn &&
        peripheralManager.state == .poweredOn
    }

    func setDiscoveryEventEpoch(_ epoch: UUID?) {
        discoveryEventEpochGate.set(epoch)
    }

    private func currentDiscoveryEventEpoch() -> UUID? {
        discoveryEventEpochGate.currentOnSourceQueue()
    }

    private func isCurrentDiscoveryEventEpoch(_ epoch: UUID) -> Bool {
        discoveryEventEpochGate.acceptsOnSourceQueue(epoch)
    }

    private override init() {
        let queue = DispatchQueue(
            label: "com.telescan.ble.manager",
            qos: .userInitiated
        )
        self.queue = queue
        self.discoveryEventEpochGate = BLESourceEpochGate(queue: queue)
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
            self.stopScanningNow(clearPresence: true)

            self.queue.asyncAfter(deadline: .now() + 0.2) {
                self.startScanningIfPossible()
            }
        }
    }

    public func stopScanning() {
        setDiscoveryEventEpoch(nil)
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

            self.removePublishedServiceIfPossible()
            self.clearPublishedServiceState()

            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.publishServiceIfPossible()
            }
        }
    }

    public func stopAdvertising() {
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldAdvertise = false
            self.removePublishedServiceIfPossible()
            self.clearPublishedServiceState()

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
                for id in self.resolvingPeripheralIDs {
                    guard let peripheral = self.discoveredPeripherals[id] else {
                        continue
                    }
                    self.scheduleForegroundIdentityTimeout(for: peripheral)
                }
                self.removeExpiredDevices()
            } else {
                self.identityResolutionTimeoutGenerations.removeAll()
            }
        }
    }

    public func reset() {
        setDiscoveryEventEpoch(nil)
        queue.async { [weak self] in
            guard let self else { return }

            self.shouldScan = false
            self.shouldAdvertise = false

            self.stopScanningNow(clearPresence: false)
            self.removePublishedServiceIfPossible()

            self.peripheralIdentities.removeAll()
            self.peripheralIdentityValidatedAt.removeAll()
            self.identityResolutionFailures.removeAll()
            self.retryNotBefore.removeAll()
            self.identityResolutionTimeoutGenerations.removeAll()
            self.devicesLastSeen.removeAll()

            self.clearPublishedServiceState()
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
        if centralManager.state == .poweredOn,
           centralManager.isScanning {
            centralManager.stopScan()
        }
        cancelIdentityResolutions()
        if shouldClearPresence {
            clearPresence(notify: true)
        }
    }

    private func cancelPeripheralConnectionIfPossible(
        _ peripheral: CBPeripheral
    ) {
        guard centralManager.state == .poweredOn,
              peripheral.state != .disconnected else {
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func acceptedEpoch(
        for peripheral: CBPeripheral
    ) -> UUID? {
        let id = peripheral.identifier
        guard discoveredPeripherals[id] === peripheral,
              resolvingPeripheralIDs.contains(id),
              let currentEpoch = currentDiscoveryEventEpoch(),
              peripheralEpochTracker.accepts(
                peripheralID: id,
                currentEpoch: currentEpoch
              ) else {
            return nil
        }
        return currentEpoch
    }

    private func removePublishedServiceIfPossible() {
        guard peripheralManager.state == .poweredOn else { return }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.removeAllServices()
    }

    private func clearPublishedServiceState() {
        identityCharacteristic = nil
        compactIdentityCharacteristic = nil
        peerIdentityWriteCharacteristic = nil
        publishedService = nil
        serviceIsPublished = false
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
            removePublishedServiceIfPossible()
            clearPublishedServiceState()
        }
    }

    private func publishServiceIfPossible() {
        guard shouldAdvertise,
              let eventEpoch = currentDiscoveryEventEpoch() else { return }

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

        removePublishedServiceIfPossible()

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

        let peerIdentityWriteCharacteristic = CBMutableCharacteristic(
            type: peerIdentityWriteCharacteristicUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(
            type: serviceUUID,
            primary: true
        )

        service.characteristics = [
            compactCharacteristic,
            characteristic,
            peerIdentityWriteCharacteristic
        ]

        identityCharacteristic = characteristic
        compactIdentityCharacteristic = compactCharacteristic
        self.peerIdentityWriteCharacteristic = peerIdentityWriteCharacteristic
        publishedService = service
        serviceIsPublished = false
        servicePublicationEpochs[ObjectIdentifier(service)] = eventEpoch

        peripheralManager.add(service)

        logger.info("Publishing BLE identity service")
    }

    private func startAdvertisingIfPossible() {
        guard shouldAdvertise,
              serviceIsPublished,
              peripheralManager.state == .poweredOn,
              let eventEpoch = currentDiscoveryEventEpoch() else {
            return
        }

        guard !advertisingEpochTracker.hasPending else {
            logger.info("Advertising waits for the prior request callback")
            return
        }

        if peripheralManager.isAdvertising {
            logger.info("Advertising is already active")
            return
        }

        let advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]

        guard advertisingEpochTracker.begin(epoch: eventEpoch) else { return }
        peripheralManager.startAdvertising(advertisement)

        logger.info("Advertising requested")
    }

    private func handleIdentity(
        _ identity: String,
        rssi: Int,
        peripheralID: UUID,
        eventEpoch: UUID,
        wasValidated: Bool = true
    ) {
        guard shouldScan, isCurrentDiscoveryEventEpoch(eventEpoch) else {
            return
        }
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
                self?.delegate?.didLoseDevice(
                    id: replacedIdentity,
                    epoch: eventEpoch
                )
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
                    rssi: rssi,
                    epoch: eventEpoch
                )
            } else {
                self.delegate?.didUpdateDevice(
                    id: canonicalIdentity,
                    rssi: rssi,
                    epoch: eventEpoch
                )
            }

            self.logger.info("Telescan device identity received")
        }
    }

    private func connectAndReadIdentity(
        peripheral: CBPeripheral,
        rssi: Int,
        eventEpoch: UUID? = nil
    ) {
        guard centralManager.state == .poweredOn else { return }

        let peripheralID = peripheral.identifier
        guard let eventEpoch = eventEpoch
                ?? peripheralEpochTracker.origin(for: peripheralID)
                ?? currentDiscoveryEventEpoch(),
              isCurrentDiscoveryEventEpoch(eventEpoch) else {
            return
        }
        if let retryDate = retryNotBefore[peripheralID], retryDate > Date() {
            return
        }

        switch peripheralEpochTracker.admit(
            peripheralID: peripheralID,
            epoch: eventEpoch
        ) {
        case .alreadyActive:
            peripheralRSSI[peripheralID] = rssi
            return

        case .deferred:
            deferredPeripheralResolutions[peripheralID] = (
                peripheral: peripheral,
                rssi: rssi
            )
            return

        case .started:
            break
        }

        resolvingPeripheralIDs.insert(peripheralID)
        discoveredPeripherals[peripheral.identifier] = peripheral
        peripheralRSSI[peripheral.identifier] = rssi
        peripheral.delegate = self

        scheduleForegroundIdentityTimeout(for: peripheral)

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

    private func scheduleForegroundIdentityTimeout(
        for peripheral: CBPeripheral
    ) {
        guard isApplicationActive else {
            logger.info(
                "Identity connection remains pending in the background"
            )
            return
        }

        let id = peripheral.identifier
        let generation = identityResolutionTimeoutGenerations[id, default: 0]
            + 1
        identityResolutionTimeoutGenerations[id] = generation

        queue.asyncAfter(
            deadline: .now() + foregroundIdentityResolutionTimeout
        ) { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  self.isApplicationActive,
                  self.resolvingPeripheralIDs.contains(id),
                  self.identityResolutionTimeoutGenerations[id]
                    == generation else {
                return
            }
            self.finishIdentityResolution(peripheral, shouldRetry: true)
        }
    }

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)

        timer.schedule(
            deadline: .now() + BLEPresencePolicy.cleanupInterval,
            repeating: BLEPresencePolicy.cleanupInterval
        )

        timer.setEventHandler { [weak self] in
            self?.removeExpiredDevices()
        }

        timer.resume()
        cleanupTimer = timer
    }

    private func removeExpiredDevices() {
        guard let eventEpoch = currentDiscoveryEventEpoch() else { return }
        let now = Date()
        let timeout = isApplicationActive
            ? BLEPresencePolicy.activeTimeout
            : BLEPresencePolicy.backgroundTimeout

        let expiredIDs = devicesLastSeen.compactMap {
            identity, lastSeen -> String? in

            now.timeIntervalSince(lastSeen) >= timeout
                ? identity
                : nil
        }

        for identity in expiredIDs {
            devicesLastSeen.removeValue(forKey: identity)

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didLoseDevice(
                    id: identity,
                    epoch: eventEpoch
                )
                self?.logger.info("Telescan device lost")
            }
        }
    }

    private func cancelIdentityResolutions() {
        deferredPeripheralResolutions.removeAll()
        peripheralEpochTracker.discardDeferred()
        for (id, peripheral) in discoveredPeripherals {
            guard peripheralEpochTracker.origin(for: id) != nil else {
                resolvingPeripheralIDs.remove(id)
                peripheralRSSI.removeValue(forKey: id)
                continue
            }
            peripheralFinishShouldRetry[id] = false
            peripheralEpochTracker.markRetiring(peripheralID: id)
            identityResolutionTimeoutGenerations.removeValue(forKey: id)
            cancelPeripheralConnectionIfPossible(peripheral)
        }
        retryNotBefore.removeAll()
        identityResolutionTimeoutGenerations.removeAll()
        identityResolutionFailures.removeAll()
    }

    private func finishIdentityResolution(
        _ peripheral: CBPeripheral,
        shouldRetry: Bool
    ) {
        let id = peripheral.identifier
        guard discoveredPeripherals[id] === peripheral,
              peripheralEpochTracker.origin(for: id) != nil else {
            return
        }
        peripheralFinishShouldRetry[id] = shouldRetry
        peripheralEpochTracker.markRetiring(peripheralID: id)
        identityResolutionTimeoutGenerations.removeValue(forKey: id)
        cancelPeripheralConnectionIfPossible(peripheral)
    }

    private func completeIdentityResolution(
        _ peripheral: CBPeripheral,
        terminalRetryDefault: Bool
    ) {
        let id = peripheral.identifier
        guard discoveredPeripherals[id] === peripheral,
              let eventEpoch = peripheralEpochTracker.origin(for: id) else {
            return
        }
        let rssi = peripheralRSSI[id] ?? -100
        let shouldRetry = peripheralFinishShouldRetry.removeValue(forKey: id)
            ?? terminalRetryDefault
        let deferredEpoch = peripheralEpochTracker.complete(peripheralID: id)
        let deferredResolution = deferredPeripheralResolutions.removeValue(
            forKey: id
        )
        resolvingPeripheralIDs.remove(id)
        discoveredPeripherals.removeValue(forKey: id)
        peripheralRSSI.removeValue(forKey: id)
        peripheralResolutionServices.removeValue(forKey: id)
        peripheralReadCharacteristics.removeValue(forKey: id)
        peripheralWriteCharacteristics.removeValue(forKey: id)
        identityResolutionTimeoutGenerations.removeValue(forKey: id)
        if shouldRetry {
            identityResolutionFailures[id, default: 0] += 1
            if identityResolutionFailures[id] == 3 {
                peripheralIdentities.removeValue(forKey: id)
                peripheralIdentityValidatedAt.removeValue(forKey: id)
            }
            retryNotBefore[id] = Date().addingTimeInterval(identityRetryDelay)
        } else {
            retryNotBefore.removeValue(forKey: id)
            identityResolutionFailures.removeValue(forKey: id)
        }

        if let deferredEpoch,
           let deferredResolution,
           shouldScan,
           isCurrentDiscoveryEventEpoch(deferredEpoch) {
            retryNotBefore.removeValue(forKey: id)
            identityResolutionFailures.removeValue(forKey: id)
            connectAndReadIdentity(
                peripheral: deferredResolution.peripheral,
                rssi: deferredResolution.rssi,
                eventEpoch: deferredEpoch
            )
            return
        }

        if shouldRetry,
           !isApplicationActive,
           shouldScan,
           isCurrentDiscoveryEventEpoch(eventEpoch),
           identityResolutionFailures[id, default: 0] < 3 {
            scheduleBackgroundIdentityRetry(
                peripheral: peripheral,
                rssi: rssi,
                eventEpoch: eventEpoch
            )
        }
    }

    private func scheduleBackgroundIdentityRetry(
        peripheral: CBPeripheral,
        rssi: Int,
        eventEpoch: UUID
    ) {
        let id = peripheral.identifier
        queue.asyncAfter(deadline: .now() + identityRetryDelay) {
            [weak self] in
            guard let self,
                  self.shouldScan,
                  self.isCurrentDiscoveryEventEpoch(eventEpoch),
                  !self.isApplicationActive,
                  !self.resolvingPeripheralIDs.contains(id) else {
                return
            }
            self.retryNotBefore.removeValue(forKey: id)
            self.logger.info("Retrying background identity resolution")
            self.connectAndReadIdentity(
                peripheral: peripheral,
                rssi: rssi,
                eventEpoch: eventEpoch
            )
        }
    }

    private func clearPresence(notify: Bool) {
        let identities = Array(devicesLastSeen.keys)
        devicesLastSeen.removeAll()
        guard notify,
              !identities.isEmpty,
              let eventEpoch = currentDiscoveryEventEpoch() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for identity in identities {
                self.delegate?.didLoseDevice(id: identity, epoch: eventEpoch)
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

    static func encodedPeerIdentityWrite(
        _ identity: UUID,
        rssi: Int
    ) -> Data? {
        guard var data = encodedIdentity(identity) else { return nil }
        let boundedRSSI = max(-100, min(-20, rssi))
        data.append(UInt8(bitPattern: Int8(boundedRSSI)))
        return data
    }

    static func decodedPeerIdentityWrite(
        _ data: Data
    ) -> PeerIdentityWrite? {
        guard data.count == 17,
              let identity = decodedIdentity(Data(data.prefix(16))) else {
            return nil
        }
        return PeerIdentityWrite(
            identity: identity,
            rssi: Int(Int8(bitPattern: data[16]))
        )
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
        guard shouldScan,
              let eventEpoch = currentDiscoveryEventEpoch() else { return }
        let rssi = RSSI.intValue

        logger.debug(
            "Discovered peripheral=\(peripheral.identifier), rssi=\(rssi), advertisement=\(advertisementData)"
        )

        if let knownIdentity = peripheralIdentities[peripheral.identifier] {
            handleIdentity(
                knownIdentity,
                rssi: rssi,
                peripheralID: peripheral.identifier,
                eventEpoch: eventEpoch,
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
                peripheralID: peripheral.identifier,
                eventEpoch: eventEpoch
            )

            return
        }

        connectAndReadIdentity(
            peripheral: peripheral,
            rssi: rssi,
            eventEpoch: eventEpoch
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
              acceptedEpoch(for: peripheral) != nil else {
            finishIdentityResolution(peripheral, shouldRetry: false)
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
        completeIdentityResolution(
            peripheral,
            terminalRetryDefault: shouldScan
                && acceptedEpoch(for: peripheral) != nil
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

        completeIdentityResolution(
            peripheral,
            terminalRetryDefault: shouldScan
                && acceptedEpoch(for: peripheral) != nil
        )
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
                guard shouldScan,
                      let eventEpoch = currentDiscoveryEventEpoch() else {
                    continue
                }
                switch peripheral.state {
                case .connected, .disconnected, .connecting, .disconnecting:
                    connectAndReadIdentity(
                        peripheral: peripheral,
                        rssi: -100,
                        eventEpoch: eventEpoch
                    )
                @unknown default:
                    break
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
              acceptedEpoch(for: peripheral) != nil else { return }
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
        peripheralResolutionServices[peripheral.identifier] = ObjectIdentifier(
            service
        )

        peripheral.discoverCharacteristics(
            [
                compactIdentityCharacteristicUUID,
                identityCharacteristicUUID,
                peerIdentityWriteCharacteristicUUID
            ],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard shouldScan,
              acceptedEpoch(for: peripheral) != nil,
              peripheralResolutionServices[id] == ObjectIdentifier(service)
        else { return }
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
        peripheralReadCharacteristics[id] = ObjectIdentifier(characteristic)

        peripheral.readValue(for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard shouldScan,
              let eventEpoch = acceptedEpoch(for: peripheral),
              peripheralReadCharacteristics[id]
                == ObjectIdentifier(characteristic) else { return }
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

        let rssi = peripheralRSSI[id] ?? -100

        handleIdentity(
            identity.uuidString,
            rssi: rssi,
            peripheralID: id,
            eventEpoch: eventEpoch
        )

        guard identity.uuidString.lowercased() != currentIdentity,
              let localIdentity = currentIdentity.flatMap(UUID.init(uuidString:)),
              let localIdentityData = Self.encodedPeerIdentityWrite(
                  localIdentity,
                  rssi: rssi
              ),
              let writeCharacteristic = characteristic.service?.characteristics?
                .first(where: {
                    $0.uuid == peerIdentityWriteCharacteristicUUID
                        && $0.properties.contains(.write)
                }) else {
            finishIdentityResolution(peripheral, shouldRetry: false)
            return
        }
        peripheralWriteCharacteristics[id] = ObjectIdentifier(
            writeCharacteristic
        )

        peripheral.writeValue(
            localIdentityData,
            for: writeCharacteristic,
            type: .withResponse
        )
        logger.info("Writing local identity to discovered Telescan device")
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard characteristic.uuid == peerIdentityWriteCharacteristicUUID,
              acceptedEpoch(for: peripheral) != nil,
              peripheralWriteCharacteristics[id]
                == ObjectIdentifier(characteristic) else { return }

        if let error {
            logger.warning(
                "Peer identity handshake failed: \(error.localizedDescription)"
            )
        } else {
            logger.info("Peer identity handshake completed")
        }

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
        let serviceKey = ObjectIdentifier(service)
        guard let eventEpoch = servicePublicationEpochs.removeValue(
            forKey: serviceKey
        ) else {
            logger.warning("Ignoring an untracked service publication callback")
            if let mutableService = service as? CBMutableService {
                peripheral.remove(mutableService)
            }
            return
        }

        guard shouldAdvertise,
              isCurrentDiscoveryEventEpoch(eventEpoch),
              publishedService === service else {
            logger.info("Discarding a stale service publication callback")
            if let mutableService = service as? CBMutableService {
                peripheral.remove(mutableService)
            }
            if publishedService === service {
                clearPublishedServiceState()
                publishServiceIfPossible()
            }
            return
        }

        if let error {
            serviceIsPublished = false

            logger.error(
                "Failed to publish service: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didFail(with: error, epoch: eventEpoch)
            }

            return
        }

        guard shouldAdvertise else {
            removePublishedServiceIfPossible()
            clearPublishedServiceState()
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
        guard let eventEpoch = advertisingEpochTracker
            .takeCompletionOrigin() else {
            logger.warning("Ignoring an untracked advertising callback")
            if peripheral.isAdvertising && !shouldAdvertise {
                peripheral.stopAdvertising()
            }
            return
        }

        guard shouldAdvertise,
              isCurrentDiscoveryEventEpoch(eventEpoch) else {
            logger.info("Discarding a stale advertising callback")
            if peripheral.isAdvertising {
                peripheral.stopAdvertising()
            }
            startAdvertisingIfPossible()
            return
        }

        if let error {
            logger.error(
                "Advertising failed: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didFail(with: error, epoch: eventEpoch)
            }

            return
        }

        logger.info("Advertising started successfully")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard request.characteristic.uuid
                    == peerIdentityWriteCharacteristicUUID,
                  request.characteristic
                    === peerIdentityWriteCharacteristic else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }

            guard request.offset == 0 else {
                peripheral.respond(to: request, withResult: .invalidOffset)
                continue
            }

            guard let data = request.value,
                  let peer = Self.decodedPeerIdentityWrite(data) else {
                peripheral.respond(
                    to: request,
                    withResult: .invalidAttributeValueLength
                )
                continue
            }

            let centralID = request.central.identifier
            if let eventEpoch = currentDiscoveryEventEpoch() {
                handleIdentity(
                    peer.identity.uuidString,
                    rssi: peer.rssi,
                    peripheralID: centralID,
                    eventEpoch: eventEpoch
                )
            }
            peripheral.respond(to: request, withResult: .success)
            logger.info("Peer identity received through GATT handshake")
        }
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

            peerIdentityWriteCharacteristic =
                restoredService.characteristics?.first(
                    where: {
                        $0.uuid == peerIdentityWriteCharacteristicUUID
                    }
                ) as? CBMutableCharacteristic

            serviceIsPublished = identityCharacteristic != nil
                && compactIdentityCharacteristic != nil
                && peerIdentityWriteCharacteristic != nil
        }

        if shouldAdvertise {
            publishServiceIfPossible()
        } else {
            removePublishedServiceIfPossible()
            clearPublishedServiceState()
        }
    }
}
