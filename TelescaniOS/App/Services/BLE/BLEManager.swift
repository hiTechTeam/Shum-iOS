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
        string: "A6B51001-8A5D-4F7A-9E4C-123456789001"
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
    private let cardCharacteristicUUID = CBUUID(string: "A6B51005-8A5D-4F7A-9E4C-123456789005")
    private var cardCharacteristic: CBMutableCharacteristic?
    private final class CardClient {
        let exchange: BLECardExchange
        let characteristic: CBCharacteristic
        var writing = false
        init(_ exchange: BLECardExchange, _ characteristic: CBCharacteristic) {
            self.exchange = exchange; self.characteristic = characteristic
        }
    }
    private final class CardServer {
        let exchange: BLECardExchange
        let central: CBCentral
        var pending: Data?
        init(_ exchange: BLECardExchange, _ central: CBCentral) {
            self.exchange = exchange; self.central = central
        }
    }
    private var cardClients: [UUID: CardClient] = [:]
    private var cardServers: [UUID: CardServer] = [:]
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
    private var recentPeripherals: [UUID: (
        peripheral: CBPeripheral,
        lastSeenAt: Date,
        rssi: Int
    )] = [:]
    private var backgroundConnectionIDs: Set<UUID> = []
    private var backgroundConnectedPeripherals: [UUID: CBPeripheral] = [:]
    private var devicesLastSeen: [String: Date] = [:]
    private var servicePublicationEpochs: [ObjectIdentifier: UUID] = [:]
    private var advertisingEpochTracker = BLESingleFlightEpochTracker()

    private let foregroundIdentityResolutionTimeout: TimeInterval = 8
    private let identityRetryDelay: TimeInterval = 3
    private let identityRevalidationInterval: TimeInterval = 30
    private let recentPeripheralMaximumAge: TimeInterval = 15 * 60
    private let recentPeripheralCapacity = 16
    private let backgroundConnectionLimit = 4
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

        currentIdentity = LocalCardStore.shared.ownManifest?.body.id.uuidString.lowercased()

        let discoveryEnabled = UserDefaults.standard.bool(
            forKey: discoveryEnabledKey
        )
        shouldScan = discoveryEnabled && currentIdentity != nil
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
            let applicationStateChanged = self.isApplicationActive != isActive
            self.isApplicationActive = isActive
            if isActive {
                self.releaseBackgroundConnections()
                if applicationStateChanged {
                    self.restartScanningForApplicationState()
                }
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
                if applicationStateChanged {
                    self.restartScanningForApplicationState()
                }
                self.armBackgroundConnections()
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
            self.recentPeripherals.removeAll()
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
                CBCentralManagerScanOptionAllowDuplicatesKey:
                    isApplicationActive
            ]
        )

        logger.info("Scanning started")
    }

    private func restartScanningForApplicationState() {
        guard shouldScan, centralManager.state == .poweredOn else { return }
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        startScanningIfPossible()
    }

    private func stopScanningNow(clearPresence shouldClearPresence: Bool) {
        if centralManager.state == .poweredOn,
           centralManager.isScanning {
            centralManager.stopScan()
        }
        releaseBackgroundConnections()
        cancelIdentityResolutions()
        if !shouldScan {
            recentPeripherals.removeAll()
        }
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

    private func recordRecentPeripheral(
        _ peripheral: CBPeripheral,
        rssi: Int,
        at date: Date = Date()
    ) {
        recentPeripherals[peripheral.identifier] = (
            peripheral: peripheral,
            lastSeenAt: date,
            rssi: rssi
        )

        guard recentPeripherals.count > recentPeripheralCapacity else { return }
        let overflow = recentPeripherals.count - recentPeripheralCapacity
        for entry in recentPeripherals
            .sorted(by: { $0.value.lastSeenAt < $1.value.lastSeenAt })
            .prefix(overflow) {
            recentPeripherals.removeValue(forKey: entry.key)
        }
    }

    private func armBackgroundConnections() {
        guard !isApplicationActive,
              shouldScan,
              centralManager.state == .poweredOn,
              let eventEpoch = currentDiscoveryEventEpoch() else { return }

        let connectedIDs = Set(backgroundConnectedPeripherals.keys)
        let availableSlots = max(
            0,
            backgroundConnectionLimit - connectedIDs.count
        )
        guard availableSlots > 0 else { return }

        let candidateIDs = BLEBackgroundReconnectPolicy.candidateIDs(
            lastSeenAt: recentPeripherals.mapValues(\.lastSeenAt),
            excluding: connectedIDs,
            now: Date(),
            maximumAge: recentPeripheralMaximumAge,
            limit: availableSlots
        )
        backgroundConnectionIDs.formUnion(candidateIDs)

        for id in candidateIDs {
            guard let recent = recentPeripherals[id],
                  peripheralIdentities[id] != currentIdentity,
                  !resolvingPeripheralIDs.contains(id) else {
                continue
            }
            connectAndReadIdentity(
                peripheral: recent.peripheral,
                rssi: recent.rssi,
                eventEpoch: eventEpoch
            )
        }

        if !candidateIDs.isEmpty {
            logger.info(
                "Armed \(candidateIDs.count) background BLE connection(s)"
            )
        }
    }

    private func retainBackgroundConnectionIfNeeded(
        _ peripheral: CBPeripheral,
        peerIdentity: UUID
    ) -> Bool {
        let id = peripheral.identifier
        guard !isApplicationActive,
              shouldScan,
              backgroundConnectionIDs.contains(id),
              let localIdentity = currentIdentity.flatMap(UUID.init(uuidString:)),
              BLEBackgroundReconnectPolicy.shouldRetainConnection(
                localIdentity: localIdentity,
                peerIdentity: peerIdentity
              ),
              discoveredPeripherals[id] === peripheral,
              peripheralEpochTracker.origin(for: id) != nil else {
            backgroundConnectionIDs.remove(id)
            return false
        }

        _ = peripheralEpochTracker.complete(peripheralID: id)
        deferredPeripheralResolutions.removeValue(forKey: id)
        resolvingPeripheralIDs.remove(id)
        discoveredPeripherals.removeValue(forKey: id)
        peripheralRSSI.removeValue(forKey: id)
        peripheralResolutionServices.removeValue(forKey: id)
        peripheralReadCharacteristics.removeValue(forKey: id)
        peripheralWriteCharacteristics.removeValue(forKey: id)
        peripheralFinishShouldRetry.removeValue(forKey: id)
        identityResolutionTimeoutGenerations.removeValue(forKey: id)
        retryNotBefore.removeValue(forKey: id)
        identityResolutionFailures.removeValue(forKey: id)
        backgroundConnectedPeripherals[id] = peripheral
        logger.info("Retaining BLE link for background wake-on-proximity")
        return true
    }

    private func releaseBackgroundConnections() {
        let connections = Array(backgroundConnectedPeripherals.values)
        backgroundConnectedPeripherals.removeAll()
        backgroundConnectionIDs.removeAll()
        for peripheral in connections {
            cancelPeripheralConnectionIfPossible(peripheral)
        }
    }

    private func rearmBackgroundConnectionIfNeeded(
        _ peripheral: CBPeripheral
    ) -> Bool {
        let id = peripheral.identifier
        guard !isApplicationActive,
              shouldScan,
              backgroundConnectionIDs.contains(id),
              let recent = recentPeripherals[id],
              let eventEpoch = currentDiscoveryEventEpoch() else {
            backgroundConnectedPeripherals.removeValue(forKey: id)
            backgroundConnectionIDs.remove(id)
            return false
        }

        backgroundConnectedPeripherals.removeValue(forKey: id)
        connectAndReadIdentity(
            peripheral: peripheral,
            rssi: recent.rssi,
            eventEpoch: eventEpoch
        )
        logger.info("Rearmed pending BLE connection in the background")
        return true
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
        cardServers.removeAll()
        cardCharacteristic = nil
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

        let card = CBMutableCharacteristic(type: cardCharacteristicUUID,
            properties: [.write, .notify], value: nil, permissions: [.writeable])
        cardCharacteristic = card
        service.characteristics = [
            card,
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
        guard resolvingPeripheralIDs.contains(peripheralID) || resolvingPeripheralIDs.count < 8 else { return }
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
        guard cardClients[peripheral.identifier] == nil else { return }
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
        cardClients.removeAll()
        cardServers.removeAll()
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
        cardClients.removeValue(forKey: id)
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
        cardClients.removeValue(forKey: id)
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

extension BLEManager {
    private func makeCardExchange(peerID: UUID, epoch: UUID) throws -> BLECardExchange {
        guard let own = LocalCardStore.shared.ownManifest else { throw LocalCardError.unavailable }
        let expected = peripheralIdentities[peerID].flatMap(UUID.init(uuidString:))
        if let expected, LocalCardStore.shared.isBlocked(expected) { throw LocalCardError.unavailable }
        return try BLECardExchange(own: own, expectedPeer: expected) { [weak self] manifest in
            guard let self, self.shouldScan, self.isCurrentDiscoveryEventEpoch(epoch) else { return }
            self.handleIdentity(manifest.body.id.uuidString,
                rssi: self.peripheralRSSI[peerID] ?? self.recentPeripherals[peerID]?.rssi ?? -70,
                peripheralID: peerID, eventEpoch: epoch)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceiveProfile(id: manifest.body.id.uuidString.lowercased(), epoch: epoch)
            }
        }
    }

    private func beginCardExchange(_ peripheral: CBPeripheral, service: CBService?) -> Bool {
        guard let epoch = acceptedEpoch(for: peripheral),
              let characteristic = service?.characteristics?.first(where: { $0.uuid == cardCharacteristicUUID }) else { return false }
        do {
            let client = CardClient(try makeCardExchange(peerID: peripheral.identifier, epoch: epoch), characteristic)
            cardClients[peripheral.identifier] = client
            identityResolutionTimeoutGenerations.removeValue(forKey: peripheral.identifier)
            peripheral.setNotifyValue(true, for: characteristic)
            queue.asyncAfter(deadline: .now() + 90) { [weak self, weak peripheral] in
                guard let self, let peripheral, self.cardClients[peripheral.identifier] === client else { return }
                self.finishIdentityResolution(peripheral, shouldRetry: true)
            }
        } catch {
            finishIdentityResolution(peripheral, shouldRetry: false)
        }
        return true
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == cardCharacteristicUUID,
              cardClients[peripheral.identifier] != nil,
              acceptedEpoch(for: peripheral) != nil else { return }
        guard error == nil, characteristic.isNotifying else {
            finishIdentityResolution(peripheral, shouldRetry: true); return
        }
        pumpCardClient(peripheral)
    }

    private func receiveCardNotification(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard acceptedEpoch(for: peripheral) != nil,
              let client = cardClients[peripheral.identifier], client.characteristic === characteristic else { return }
        do {
            guard error == nil, let data = characteristic.value else { throw LocalCardError.invalidPacket }
            try client.exchange.receive(data)
            pumpCardClient(peripheral)
        } catch { finishIdentityResolution(peripheral, shouldRetry: true) }
    }

    private func pumpCardClient(_ peripheral: CBPeripheral) {
        guard shouldScan, acceptedEpoch(for: peripheral) != nil,
              let client = cardClients[peripheral.identifier], !client.writing,
              client.characteristic.isNotifying else { return }
        if let peer = client.exchange.peer, LocalCardStore.shared.isBlocked(peer.body.id) {
            finishIdentityResolution(peripheral, shouldRetry: false); return
        }
        if let frame = client.exchange.nextFrame(maximumBytes: min(512, peripheral.maximumWriteValueLength(for: .withResponse))) {
            client.writing = true
            peripheral.writeValue(frame, for: client.characteristic, type: .withResponse)
        } else if client.exchange.complete {
            cardClients.removeValue(forKey: peripheral.identifier)
            // End this exchange even when keeping the background connection.
            // A later refresh must subscribe afresh and receive a new manifest.
            peripheral.setNotifyValue(false, for: client.characteristic)
            if let peer = client.exchange.peer,
               retainBackgroundConnectionIfNeeded(peripheral, peerIdentity: peer.body.id) { return }
            finishIdentityResolution(peripheral, shouldRetry: false)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic === cardCharacteristic, shouldAdvertise, shouldScan,
              cardServers.count < 8, let epoch = currentDiscoveryEventEpoch() else { return }
        do {
            let server = CardServer(try makeCardExchange(peerID: central.identifier, epoch: epoch), central)
            cardServers[central.identifier] = server
            pumpCardServer(server)
            queue.asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self, self.cardServers[central.identifier] === server else { return }
                self.cardServers.removeValue(forKey: central.identifier)
            }
        } catch { cardServers.removeValue(forKey: central.identifier) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == cardCharacteristicUUID { cardServers.removeValue(forKey: central.identifier) }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for server in Array(cardServers.values) { pumpCardServer(server) }
    }

    private func receiveCardWrite(_ request: CBATTRequest) {
        guard request.characteristic === cardCharacteristic, request.offset == 0,
              shouldAdvertise, shouldScan, currentDiscoveryEventEpoch() != nil,
              let server = cardServers[request.central.identifier], let data = request.value else {
            peripheralManager.respond(to: request, withResult: .requestNotSupported); return
        }
        do {
            try server.exchange.receive(data)
            peripheralManager.respond(to: request, withResult: .success)
            pumpCardServer(server)
        } catch {
            cardServers.removeValue(forKey: request.central.identifier)
            peripheralManager.respond(to: request, withResult: .invalidAttributeValueLength)
        }
    }

    private func pumpCardServer(_ server: CardServer) {
        guard shouldAdvertise, shouldScan, let characteristic = cardCharacteristic,
              peripheralManager.state == .poweredOn else { return }
        if let peer = server.exchange.peer, LocalCardStore.shared.isBlocked(peer.body.id) {
            cardServers.removeValue(forKey: server.central.identifier); return
        }
        while true {
            if server.pending == nil {
                server.pending = server.exchange.nextFrame(maximumBytes: min(512, server.central.maximumUpdateValueLength))
            }
            guard let frame = server.pending else { return }
            guard peripheralManager.updateValue(frame, for: characteristic, onSubscribedCentrals: [server.central]) else { return }
            server.pending = nil
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
            armBackgroundConnections()

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
        recordRecentPeripheral(peripheral, rssi: rssi)

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

        if rearmBackgroundConnectionIfNeeded(peripheral) {
            return
        }

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
        ) && currentIdentity != nil

        if let peripherals =
            dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral] {

            for peripheral in peripherals {
                guard shouldScan,
                      let eventEpoch = currentDiscoveryEventEpoch() else {
                    continue
                }
                recordRecentPeripheral(peripheral, rssi: -100)
                backgroundConnectionIDs.insert(peripheral.identifier)
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
                peerIdentityWriteCharacteristicUUID,
                cardCharacteristicUUID
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
        if characteristic.uuid == cardCharacteristicUUID {
            receiveCardNotification(peripheral, characteristic: characteristic, error: error)
            return
        }
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

        guard identity.uuidString.lowercased() != currentIdentity else {
            backgroundConnectionIDs.remove(id)
            finishIdentityResolution(peripheral, shouldRetry: false)
            return
        }

        guard let localIdentity = currentIdentity.flatMap(UUID.init(uuidString:)),
              let localIdentityData = Self.encodedPeerIdentityWrite(
                  localIdentity,
                  rssi: rssi
              ),
              let writeCharacteristic = characteristic.service?.characteristics?
                .first(where: {
                    $0.uuid == peerIdentityWriteCharacteristicUUID
                        && $0.properties.contains(.write)
                }) else {
            if retainBackgroundConnectionIfNeeded(
                peripheral,
                peerIdentity: identity
            ) {
                return
            }
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
        if characteristic.uuid == cardCharacteristicUUID {
            guard let client = cardClients[peripheral.identifier],
                  acceptedEpoch(for: peripheral) != nil else { return }
            if error != nil { finishIdentityResolution(peripheral, shouldRetry: true); return }
            client.writing = false
            pumpCardClient(peripheral)
            return
        }
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
            if beginCardExchange(peripheral, service: characteristic.service) { return }
            if let peerIdentity = peripheralIdentities[id]
                .flatMap(UUID.init(uuidString:)),
               retainBackgroundConnectionIfNeeded(
                    peripheral,
                    peerIdentity: peerIdentity
               ) {
                return
            }
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
            if request.characteristic.uuid == cardCharacteristicUUID {
                receiveCardWrite(request)
                continue
            }
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
