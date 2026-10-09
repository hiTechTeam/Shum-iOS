import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    private static let restoredPasscodeSetupKey = "shum.restore.needsPasscodeSetup"
    @Published var isRegistered = false
    @Published private(set) var needsSecuritySetup = false
    @Published var authenticationFlowID = UUID()
    @Published var hasCompletedInitialSessionRefresh = true
    @Published var nearbyNotificationNavigationRequest = UUID()
    @Published var chatNotificationPeerID: String?
    @Published var showSplash = true
    @Published var isScaning = false
    @Published private(set) var chat: ShumRuntime?
    @Published var deletionError: String?
    @Published var invitation: ShumContactCard?
    @Published var invitationError: String?
    @Published var deletingProfile = false
    @Published private(set) var showsDeletionCeremony = false
    let authCodeViewModel: LocalProfileViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel
    private let deletion = ShumDeletionService.live()
    private let nearbyPeopleNotifier = NearbyPeopleNotifier()
    private var photoObserver: NSObjectProtocol?
    private var chatObserver: AnyCancellable?
    private var notificationRefreshTask: Task<Void, Never>?
    private var notificationSnapshotInitialized = false
    private var notifiedIncomingMessageIDs: Set<String> = []
    private var notifiedInvitationIDs: Set<String> = []
    private var notifiedOutgoingInvitationIDs: Set<String> = []
    private var notifiedNearbyPeerIDs: Set<String> = []
    private var didSynchronizeBackgroundNearby = false
    private var active = false
    private var storageTeardownInProgress = false
    private var pendingInvitationURL: URL?

    init() {
        let store = LocalCardStore.shared
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview"), store.ownManifest == nil {
            _ = try? store.saveOwn(name: "Руслан", bio: "Пробую Shum", photo: nil)
        }
        #endif
        authCodeViewModel = LocalProfileViewModel()
        profilePhotoViewModel = ProfilePhotoViewModel()
        #if DEBUG
        if TestEnvironment.isRunningTests { return }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let previewsOnboarding = ProcessInfo.processInfo.arguments.contains("-ShumPreviewOnboarding")
        #else
        let previewsOnboarding = false
        #endif
        AppNotificationRouter.shared.configure(
            openNearby: { [weak self] in
                self?.nearbyNotificationNavigationRequest = UUID()
            },
            openChat: { [weak self] peerID in
                self?.chatNotificationPeerID = peerID
            }
        )
        let hasProfile = store.ownManifest != nil
        let registrationCompleted = UserDefaults.standard.bool(
            forKey: Keys.isReg.rawValue
        )
        isRegistered = hasProfile && registrationCompleted && !previewsOnboarding
        needsSecuritySetup = hasProfile && !registrationCompleted && !previewsOnboarding
        #if DEBUG && targetEnvironment(simulator)
        // UI fixtures can be opened on a fresh simulator without creating a
        // real profile. This path is absent from every physical-device build.
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview"), !previewsOnboarding {
            isRegistered = true
            needsSecuritySetup = false
        }
        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewDeletion") {
            isRegistered = false
            needsSecuritySetup = false
            showsDeletionCeremony = true
        }
        #endif
        isScaning = isRegistered && UserDefaults.standard.bool(forKey: Keys.isScaning.rawValue)
        if deletion.hasDeletion {
            deletingProfile = true
            finishDeletion()
        } else if isRegistered {
            prepareMessaging()
        } else if needsSecuritySetup {
            createMessaging(bluetoothEnabled: false, deferHistoryLoading: true)
        }
        photoObserver = NotificationCenter.default.addObserver(forName: .localCardChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.authCodeViewModel.restoreLocalProfile()
                self?.synchronizeProfile()
            }
        }
        ShumPushService.shared.configureBackgroundWake { [weak self] eventID, completion in
            guard let self, self.isRegistered, let chat = self.chat else {
                completion(.noData)
                return
            }
            chat.fetchRemoteEvents(eventID: eventID) { [weak self] receivedData in
                Task { @MainActor in
                    if let self, let chat = self.chat {
                        self.refreshNotificationState(for: chat)
                        await self.nearbyPeopleNotifier.applyApplicationIconBadge()
                    }
                    completion(receivedData ? .newData : .noData)
                }
            }
        }
    }
    deinit { if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) } }
    func start() -> AnyView {
        AnyView(AppCoordinatorView().environmentObject(self)
            .environmentObject(authCodeViewModel))
    }
    private func prepareMessaging() {
        guard !deletingProfile, isRegistered else { return }
        createMessaging(
            bluetoothEnabled: isScaning && !ShumAppLock.shared.isLocked
        )
    }
    private func createMessaging(bluetoothEnabled: Bool, deferHistoryLoading: Bool? = nil) {
        guard chat == nil else {
            chat?.setBluetoothEnabled(bluetoothEnabled)
            return
        }
        let model = ShumRuntime.live(deferHistoryLoading: deferHistoryLoading ?? isRegistered)
        model.onReady = { [weak self] in
            guard let self, !self.deletingProfile else { return }
            self.synchronizeProfile()
            self.objectWillChange.send()
            self.updateApplicationState(isActive: self.active)
            if let pending = self.pendingInvitationURL {
                self.pendingInvitationURL = nil
                self.handleInvitationURL(pending)
            }
        }
        model.deleteProfileHandler = { [weak self] in
            Task { @MainActor in try? await self?.deleteAccount() }
        }
        model.setBluetoothEnabled(bluetoothEnabled)
        model.setAppActive(false)
        chat = model
        observeNotifications(in: model)
        synchronizeProfile()
    }
    @discardableResult
    func prepareInitialRegistrationIdentity() -> Bool {
        guard !deletingProfile, !isRegistered else {
            return false
        }
        // The ceremony needs only the local profile key. Messaging, Bluetooth,
        // relays and history are initialized after the user saves their profile.
        do { try profilePhotoViewModel.prepareRegistrationAvatar() }
        catch { return false }
        return profilePhotoViewModel.avatarSeed != nil
    }
    @discardableResult
    func prepareRegistrationSecurity() -> Bool {
        guard !deletingProfile, LocalCardStore.shared.ownManifest != nil else {
            return false
        }
        createMessaging(bluetoothEnabled: false)
        synchronizeProfile()
        guard let own = LocalCardStore.shared.ownManifest else { return false }
        return chat?.isReady == true
            && chat?.permanent?.ownCard.name == own.body.name
            && chat?.permanent?.ownCard.avatarSeed == own.body.avatarSeed
    }
    var identityFingerprint: String? {
        guard let value = chat?.permanent?.ownCard.id, !value.isEmpty else {
            return nil
        }
        let characters = Array(value.uppercased().prefix(12))
        return stride(from: 0, to: characters.count, by: 4)
            .map { start in
                String(characters[start..<min(start + 4, characters.count)])
            }
            .joined(separator: " ")
    }
    func retryMessaging() {
        chatObserver?.cancel()
        chat?.retireForDeletion()
        chat = nil
        prepareMessaging()
        updateApplicationState(isActive: active)
    }
    private func synchronizeProfile() {
        guard !deletingProfile, var own = LocalCardStore.shared.ownManifest, let chat, chat.isReady else { return }
        if own.body.avatarSeed == nil,
           let migrated = try? LocalCardStore.shared.saveOwn(name: own.body.name,
               bio: own.body.bio, photo: nil) {
            own = migrated
            profilePhotoViewModel.loadPhotoIfNeeded()
        }
        guard let seed = own.body.avatarSeed else { return }
        let profile = ShumProfile(name: own.body.name, bio: own.body.bio ?? "",
            avatarSeed: seed).rendered()
        if chat.profiles.own != profile {
            _ = chat.saveProfile(name: profile.name, bio: profile.bio, avatarSeed: seed)
        }
    }
    func completedRegistration() {
        guard LocalCardStore.shared.ownManifest != nil else { return }
        UserDefaults.standard.set(false, forKey: Self.restoredPasscodeSetupKey)
        authCodeViewModel.restoreLocalProfile()
        profilePhotoViewModel.loadPhotoIfNeeded()
        needsSecuritySetup = false
        isRegistered = true
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        isScaning = true
        UserDefaults.standard.set(true, forKey: Keys.isScaning.rawValue)

        // The security screens use a runtime whose Bluetooth managers are
        // deliberately never created. Rebuild it after registration so the
        // first live session follows the same clean startup path as a normal
        // app launch instead of depending on a background/foreground cycle.
        chatObserver?.cancel()
        chat = nil
        prepareMessaging()
        synchronizeProfile()
        updateApplicationState(isActive: active)
    }

    @discardableResult
    func prepareRestoredProfileForSecurity() async -> Bool {
        guard !isRegistered, !deletingProfile else { return false }
        LocalCardStore.shared.reloadFromDisk()
        guard LocalCardStore.shared.ownManifest != nil else { return false }
        UserDefaults.standard.set(false, forKey: Keys.isReg.rawValue)
        authCodeViewModel.restoreLocalProfile()
        profilePhotoViewModel.loadPhotoIfNeeded()
        needsSecuritySetup = true
        UserDefaults.standard.set(true, forKey: Self.restoredPasscodeSetupKey)
        if chat?.isReady == false {
            chatObserver?.cancel()
            chat?.retireForDeletion()
            chat = nil
        }
        createMessaging(bluetoothEnabled: false, deferHistoryLoading: true)
        await chat?.waitUntilHistoryLoaded()
        return prepareRegistrationSecurity()
    }
    var needsRestoredPasscodeSetup: Bool {
        needsSecuritySetup && UserDefaults.standard.bool(forKey: Self.restoredPasscodeSetupKey)
    }
    func setScanning(_ enabled: Bool) {
        isScaning = enabled && isRegistered
        UserDefaults.standard.set(isScaning, forKey: Keys.isScaning.rawValue)
        updateApplicationState(isActive: active)
    }
    func refreshSession() async {
        authCodeViewModel.restoreLocalProfile(); profilePhotoViewModel.loadPhotoIfNeeded()
        synchronizeProfile()
    }
    func handleInvitationURL(_ url: URL) {
        if isRegistered, chat?.isLoadingHistory == true {
            pendingInvitationURL = url
            return
        }
        guard isRegistered,
              LocalCardStore.shared.ownManifest != nil,
              chat?.isReady == true else {
            invitation = nil
            invitationError = "Сначала завершите регистрацию в Shum: получите ключи и создайте свой профиль. Затем откройте контакт ещё раз.".localized
            return
        }

        do {
            switch try ShumInvitationPayload.parse(url) {
            case .card(let card):
                invitationError = nil
                invitation = card
            case .locator(let locator):
                guard let chat else { throw ShumFailure.unavailableIdentity }
                invitationError = nil
                chat.resolveContact(locator) { [weak self] result in
                    switch result {
                    case .success(let card):
                        self?.invitation = card
                    case .failure(let error):
                        self?.invitationError = error.localizedDescription
                    }
                }
            }
        } catch {
            invitationError = error.localizedDescription
        }
    }
    func deleteAccount() async throws {
        try deletion.begin()
        deletingProfile = true
        pendingInvitationURL = nil
        ShumPushService.shared.unregisterCurrentDevice()
        chatObserver?.cancel()
        let retiringChat = chat
        retiringChat?.retireForDeletion(); chat = nil
        // Migration may still be committing on its worker. Delete files only
        // after it has stopped; it must never recreate an erased account.
        storageTeardownInProgress = true
        await retiringChat?.waitForStoragePreparation()
        storageTeardownInProgress = false
        finishDeletion()
        if deletingProfile { throw ShumFailure.storage }
    }
    func finishDeletion() {
        guard !storageTeardownInProgress else { return }
        do {
            try deletion.finish()
            try LocalCardStore.shared.reset()
            AccountSessionGeneration.shared.advance()
            authCodeViewModel.clearProfile(); profilePhotoViewModel.resetAccountScopedState()
            SavedPeopleStateStore.shared.removeAll(); QuickActionsSettingsStore.shared.reset()
            ShumAppLock.shared.reset()
            UserDefaults.standard.set(false, forKey: Self.restoredPasscodeSetupKey)
            try deletion.allowNewProfile()
            isRegistered = false; needsSecuritySetup = false; isScaning = false
            resetNotificationState()
            deletionError = nil; deletingProfile = false
            showsDeletionCeremony = true
        } catch { deletionError = "Удаление не завершено. Разблокируйте iPhone и повторите. Обмен сообщениями остановлен.".localized }
    }
    func completeDeletionCeremony() {
        ShumAppearanceStore.shared.resetToClassic()
        showsDeletionCeremony = false
        authenticationFlowID = UUID()
    }
    func updateApplicationState(isActive: Bool) {
        active = isActive
        if isActive {
            didSynchronizeBackgroundNearby = false
        }
        guard !deletingProfile, isRegistered, let chat else {
            nearbyPeopleNotifier.setScanningEnabled(false)
            nearbyPeopleNotifier.setApplicationActive(false)
            return
        }
        let hasCompletedLogin = !ShumAppLock.shared.isLocked
        let notificationsAreActive = isActive && hasCompletedLogin
        nearbyPeopleNotifier.setApplicationActive(notificationsAreActive)
        nearbyPeopleNotifier.setScanningEnabled(
            isScaning && hasCompletedLogin
        )
        chat.setBluetoothEnabled(isScaning && hasCompletedLogin)
        chat.setAppActive(notificationsAreActive)
        if isActive && hasCompletedLogin { chat.start() }
        refreshNotificationState(for: chat)
    }

    func clearChatNotificationPeerID() {
        chatNotificationPeerID = nil
    }

    func refreshNotificationState() {
        guard let chat else { return }
        refreshNotificationState(for: chat)
    }

    private func observeNotifications(in runtime: ShumRuntime) {
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        notificationSnapshotInitialized = false
        notifiedIncomingMessageIDs.removeAll()
        notifiedInvitationIDs.removeAll()
        notifiedOutgoingInvitationIDs.removeAll()
        notifiedNearbyPeerIDs.removeAll()
        chatObserver = runtime.objectWillChange.sink { [weak self, weak runtime] _ in
            guard let self, self.notificationRefreshTask == nil else { return }
            // Published changes arrive in bursts. Scan the final state once
            // after the burst instead of queuing a full scan for every field.
            self.notificationRefreshTask = Task { @MainActor [weak self, weak runtime] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard let self, let runtime, self.chat === runtime else {
                    return
                }
                self.notificationRefreshTask = nil
                self.refreshNotificationState(for: runtime)
            }
        }
        refreshNotificationState(for: runtime)
    }

    private func refreshNotificationState(for runtime: ShumRuntime) {
        guard !deletingProfile, isRegistered,
              let permanent = runtime.permanent else { return }

        let incomingMessages = permanent.state.messages.filter {
            !$0.outgoing && $0.unread
        }
        let incomingMessageIDs = Set(incomingMessages.map(\.id))
        let invitations = permanent.state.requests.filter {
            permanent.invitationPhase(for: $0) == .incomingPending
        }
        let invitationIDs = Set(invitations.map(\.id))
        let invitationStates = permanent.state.invitationStates ?? [:]
        let outgoingInvitationIDs = Set(
            invitationStates.filter { $0.value.phase == .outgoingPending }.keys
        )
        let entries = runtime.directoryEntries
        let nearbyIDs = Set(
            entries.filter(\.isNearby).map { $0.peer.id.id }
        )

        if notificationSnapshotInitialized
            && (!active || ShumAppLock.shared.isLocked) {
            for message in incomingMessages where
                !notifiedIncomingMessageIDs.contains(message.id) {
                if ShumPushService.shared.consumeRemoteEvent(message.id) {
                    continue
                }
                AppNotificationRouter.shared.scheduleMessage(
                    id: message.id,
                    peerID: message.envelope.sender.peerID.id,
                    senderName: message.envelope.sender.name,
                    text: message.text
                )
            }
            for invitation in invitations where
                !notifiedInvitationIDs.contains(invitation.id) {
                if let eventID = permanent.state.invitationStates?[
                    invitation.id
                ]?.eventID,
                   ShumPushService.shared.consumeRemoteEvent(eventID) {
                    continue
                }
                AppNotificationRouter.shared.scheduleInvitation(
                    peerID: invitation.peerID.id,
                    senderName: invitation.name
                )
            }
            // Our invitation that the other person has accepted since the last
            // look. Its push is silent, so this is the only notice.
            for id in notifiedOutgoingInvitationIDs.subtracting(outgoingInvitationIDs) {
                guard invitationStates[id]?.phase == .accepted,
                      let card = permanent.state.contacts.first(where: { $0.id == id })?.card
                else { continue }
                AppNotificationRouter.shared.scheduleInvitationAccepted(
                    peerID: card.peerID.id,
                    senderName: card.name
                )
            }
        }

        notifiedIncomingMessageIDs = incomingMessageIDs
        notifiedInvitationIDs = invitationIDs
        notifiedOutgoingInvitationIDs = outgoingInvitationIDs
        notificationSnapshotInitialized = true

        if !active || ShumAppLock.shared.isLocked {
            if UIApplication.shared.applicationState == .background,
               !didSynchronizeBackgroundNearby {
                nearbyPeopleNotifier.synchronizeNearby(ids: nearbyIDs)
                didSynchronizeBackgroundNearby = true
            }
            for id in nearbyIDs.subtracting(notifiedNearbyPeerIDs) {
                nearbyPeopleNotifier.detect(id: id)
            }
            for id in notifiedNearbyPeerIDs.subtracting(nearbyIDs) {
                nearbyPeopleNotifier.lose(id: id)
            }
        }
        notifiedNearbyPeerIDs = nearbyIDs

        nearbyPeopleNotifier.setApplicationIconBadgeCount(entries.badgeCount)
    }

    private func resetNotificationState() {
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        chatObserver?.cancel()
        chatObserver = nil
        notificationSnapshotInitialized = false
        notifiedIncomingMessageIDs.removeAll()
        notifiedInvitationIDs.removeAll()
        notifiedOutgoingInvitationIDs.removeAll()
        notifiedNearbyPeerIDs.removeAll()
        didSynchronizeBackgroundNearby = false
        nearbyPeopleNotifier.setScanningEnabled(false)
        nearbyPeopleNotifier.reset()
        nearbyPeopleNotifier.setApplicationIconBadgeCount(0)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
