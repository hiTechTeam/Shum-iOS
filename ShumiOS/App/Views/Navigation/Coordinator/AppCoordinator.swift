import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
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
    let peopleViewModel: PeopleViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel
    private let deletion = ShumDeletionService.live()
    private let nearbyPeopleNotifier = NearbyPeopleNotifier()
    private var photoObserver: NSObjectProtocol?
    private var chatObserver: AnyCancellable?
    private var notificationSnapshotInitialized = false
    private var notifiedIncomingMessageIDs: Set<String> = []
    private var notifiedInvitationIDs: Set<String> = []
    private var notifiedNearbyPeerIDs: Set<String> = []
    private var didSynchronizeBackgroundNearby = false
    private var active = false

    init() {
        let store = LocalCardStore.shared
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview"), store.ownManifest == nil {
            _ = try? store.saveOwn(name: "Руслан", bio: "Пробую Shum", photo: nil)
        }
        #endif
        authCodeViewModel = LocalProfileViewModel()
        profilePhotoViewModel = ProfilePhotoViewModel()
        peopleViewModel = PeopleViewModel(
            bleManager: ShumInactiveCardRadio(),
            nearbyPeopleNotifier: ShumInactiveNearbyPeopleNotifier()
        )
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
            _ = prepareRegistrationSecurity()
        }
        photoObserver = NotificationCenter.default.addObserver(forName: .localCardChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.authCodeViewModel.restoreLocalProfile()
                self?.synchronizeProfile()
            }
        }
    }
    deinit { if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) } }
    func start() -> AnyView {
        AnyView(AppCoordinatorView().environmentObject(self)
            .environmentObject(authCodeViewModel).environmentObject(peopleViewModel))
    }
    private func prepareMessaging() {
        guard !deletingProfile, isRegistered else { return }
        createMessaging(
            bluetoothEnabled: isScaning && !ShumAppLock.shared.isLocked
        )
    }
    private func createMessaging(bluetoothEnabled: Bool) {
        guard chat == nil else {
            chat?.setBluetoothEnabled(bluetoothEnabled)
            return
        }
        let model = ShumRuntime.live()
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
    func prepareRegistrationSecurity() -> Bool {
        guard !deletingProfile, LocalCardStore.shared.ownManifest != nil else {
            return false
        }
        createMessaging(bluetoothEnabled: false)
        synchronizeProfile()
        return chat?.isReady == true && chat?.permanent?.ownCard.id.isEmpty == false
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
        guard !deletingProfile, let own = LocalCardStore.shared.ownManifest, let chat, chat.isReady else { return }
        let avatar = LocalCardStore.shared.photo(own.body.photoHash)
        let profile = ShumProfile(name: own.body.name, bio: own.body.bio ?? "", avatar: avatar)
        if chat.profiles.own != profile { _ = chat.saveProfile(name: profile.name, bio: profile.bio, avatar: profile.avatar) }
    }
    func completedRegistration() {
        guard LocalCardStore.shared.ownManifest != nil else { return }
        authCodeViewModel.restoreLocalProfile()
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
    func prepareRestoredProfileForSecurity() -> Bool {
        guard !isRegistered, !deletingProfile else { return false }
        LocalCardStore.shared.reloadFromDisk()
        guard LocalCardStore.shared.ownManifest != nil else { return false }
        UserDefaults.standard.set(false, forKey: Keys.isReg.rawValue)
        authCodeViewModel.restoreLocalProfile()
        profilePhotoViewModel.loadPhotoIfNeeded()
        needsSecuritySetup = true
        return prepareRegistrationSecurity()
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
        guard isRegistered,
              LocalCardStore.shared.ownManifest != nil,
              chat?.isReady == true else {
            invitation = nil
            invitationError = "Сначала завершите регистрацию в Shum: получите ключи и создайте свой профиль. Затем откройте контакт ещё раз."
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
        chatObserver?.cancel()
        chat?.retireForDeletion(); chat = nil
        finishDeletion()
        if deletingProfile { throw ShumFailure.storage }
    }
    func finishDeletion() {
        do {
            try deletion.finish()
            try LocalCardStore.shared.reset()
            AccountSessionGeneration.shared.advance()
            peopleViewModel.resetAccountScopedState()
            authCodeViewModel.clearProfile(); profilePhotoViewModel.resetAccountScopedState()
            SavedPeopleStateStore.shared.removeAll(); QuickActionsSettingsStore.shared.reset()
            ShumAppLock.shared.reset()
            try deletion.allowNewProfile()
            isRegistered = false; needsSecuritySetup = false; isScaning = false
            resetNotificationState()
            deletionError = nil; deletingProfile = false
            showsDeletionCeremony = true
        } catch { deletionError = "Удаление не завершено. Разблокируйте iPhone и повторите. Обмен сообщениями остановлен." }
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
        notificationSnapshotInitialized = false
        notifiedIncomingMessageIDs.removeAll()
        notifiedInvitationIDs.removeAll()
        notifiedNearbyPeerIDs.removeAll()
        chatObserver = runtime.objectWillChange.sink { [weak self, weak runtime] _ in
            Task { @MainActor in
                await Task.yield()
                guard let self, let runtime, self.chat === runtime else {
                    return
                }
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
        let entries = runtime.directoryEntries
        let nearbyIDs = Set(
            entries.filter(\.isNearby).map { $0.peer.id.id }
        )

        if notificationSnapshotInitialized
            && (!active || ShumAppLock.shared.isLocked) {
            for message in incomingMessages where
                !notifiedIncomingMessageIDs.contains(message.id) {
                AppNotificationRouter.shared.scheduleMessage(
                    id: message.id,
                    peerID: message.envelope.sender.peerID.id,
                    senderName: message.envelope.sender.name,
                    text: message.text
                )
            }
            for invitation in invitations where
                !notifiedInvitationIDs.contains(invitation.id) {
                AppNotificationRouter.shared.scheduleInvitation(
                    peerID: invitation.peerID.id,
                    senderName: invitation.name
                )
            }
        }

        notifiedIncomingMessageIDs = incomingMessageIDs
        notifiedInvitationIDs = invitationIDs
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

        let chatBadgeCount = entries.reduce(0) {
            $0 + max(
                $1.unread,
                $1.invitationAwaitingResponse ? 1 : 0
            )
        }
        let totalBadgeCount = chatBadgeCount
            + nearbyIDs.count
            + permanent.unviewedEncounterCount
        nearbyPeopleNotifier.setApplicationIconBadgeCount(totalBadgeCount)
    }

    private func resetNotificationState() {
        chatObserver?.cancel()
        chatObserver = nil
        notificationSnapshotInitialized = false
        notifiedIncomingMessageIDs.removeAll()
        notifiedInvitationIDs.removeAll()
        notifiedNearbyPeerIDs.removeAll()
        didSynchronizeBackgroundNearby = false
        nearbyPeopleNotifier.setScanningEnabled(false)
        nearbyPeopleNotifier.reset()
        nearbyPeopleNotifier.setApplicationIconBadgeCount(0)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
