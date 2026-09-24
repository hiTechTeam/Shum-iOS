import SwiftUI
import UIKit

struct PeopleView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedUser: NearbyUser?
    @State private var moderationRequest: ProfileModerationRequest?
    @State private var messengerTransitionRequest: MessengerTransitionRequest?
    @State private var showsSavedBlockInformation = false
    @State private var showsQuickBlockError = false

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if coordinator.isScaning {
                if peopleViewModel.visibleUsers.isEmpty {
                    GeometryReader { geometry in
                        ScrollView {
                            ShumContentUnavailableView(
                                Inc.Scanning.emptyTitle.localized,
                                systemImage: "wave.3.up",
                                description: Text(
                                    Inc.Scanning.noPeopleNeaby.localized
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        }
                        .shumAlwaysBounce()
                        .refreshable {
                            await peopleViewModel.refreshNearbyPeople()
                        }
                    }
                } else {
                    AdaptiveSystemSwipeList(
                        items: peopleViewModel.visibleUsers,
                        descriptionText: Inc.Scanning.listDescription.localized,
                        refreshAction: {
                            await peopleViewModel.refreshNearbyPeople()
                        },
                        leadingActions: { _, _ in
                            [
                                .save(
                                    title: Inc.EncounterHistory.save.localized,
                                    removeTitle: Inc.EncounterHistory.remove
                                        .localized
                                )
                            ]
                        },
                        trailingActions: { user, isSaved in
                            if isSaved {
                                [
                                    SystemSwipeAction(
                                        title: Inc.NearbyProfile.savedBlockAction
                                            .localized,
                                        systemImage: "lock.fill",
                                        backgroundColor: .systemGray,
                                        style: .normal,
                                        handler: {
                                            requestSavedBlockInformation()
                                        }
                                    )
                                ]
                            } else {
                                [
                                    SystemSwipeAction(
                                        title: Inc.NearbyProfile.block.localized,
                                        systemImage: "person.crop.circle.badge.xmark",
                                        backgroundColor: .systemRed,
                                        style: quickActions.isQuickBlockEnabled
                                            ? .destructive
                                            : .normal,
                                        handler: {
                                            handleSwipeBlock(user)
                                        }
                                    )
                                ]
                            }
                        }
                    ) { user, isSaved in
                        ProfileAvatarButton(
                            user: user,
                            isSaved: isSaved,
                            cardAction: { openInfo(for: user) },
                            messengerAction: { openUser(user) },
                            blockAction: {
                                if isSaved {
                                    requestSavedBlockInformation()
                                } else {
                                    moderationRequest = ProfileModerationRequest(
                                        user: user,
                                        accountGeneration: peopleViewModel
                                            .accountStateGeneration,
                                        waitsForTransientUI: false
                                    )
                                }
                            }
                        )
                        .environmentObject(peopleViewModel)
                    }
                }
            } else {
                ShumContentUnavailableView(
                    Inc.Scanning.scanning.localized,
                    systemImage: "eye.slash",
                    description: Text(
                        Inc.Scanning.turnedOffScanning.localized
                    )
                )
            }
        }
        .shumOnChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            guard coordinator.isScaning else {
                return
            }

            Task {
                await peopleViewModel.synchronizeBlockedProfiles()
                await peopleViewModel.refreshVisibleUsers()
            }
        }
        .shumOnChange(of: peopleViewModel.visibleUsers.map(\.id)) { _, ids in
            if let selectedUser, !ids.contains(selectedUser.id) {
                self.selectedUser = nil
            }
            if let moderationRequest,
               !ids.contains(moderationRequest.user.id) {
                self.moderationRequest = nil
            }
            if let messengerTransitionRequest,
               !ids.contains(messengerTransitionRequest.userID) {
                self.messengerTransitionRequest = nil
            }
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .messengerTransitionAlert(request: $messengerTransitionRequest)
        .profileModerationDialog(request: $moderationRequest)
        .alert(
            Inc.NearbyProfile.savedBlockTitle.localized,
            isPresented: $showsSavedBlockInformation
        ) {
            Button(Inc.NearbyProfile.savedBlockOK.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.savedBlockMessage.localized)
        }
        .alert(
            Inc.NearbyProfile.actionFailedTitle.localized,
            isPresented: $showsQuickBlockError
        ) {
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.actionFailedMessage.localized)
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
    }

    private func openUser(_ user: NearbyUser) {
        guard !peopleViewModel.isProfileBlocked(user.id) else { return }
        guard let destination = MessengerChatDestination(user: user) else {
            selectedUser = user
            return
        }

        if quickActions.isQuickChatEnabled {
            destination.open(using: openURL)
            return
        }

        messengerTransitionRequest = MessengerTransitionRequest(
            userID: user.id,
            accountGeneration: peopleViewModel.accountStateGeneration,
            destination: destination
        )
    }

    private func openInfo(for user: NearbyUser) {
        guard !peopleViewModel.isProfileBlocked(user.id) else { return }
        selectedUser = user
    }

    private func handleSwipeBlock(_ user: NearbyUser) {
        guard quickActions.isQuickBlockEnabled else {
            moderationRequest = ProfileModerationRequest(
                user: user,
                accountGeneration: peopleViewModel.accountStateGeneration,
                waitsForTransientUI: true
            )
            return
        }

        let generation = peopleViewModel.accountStateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard peopleViewModel.isCurrentAccountStateGeneration(generation),
                  peopleViewModel.visibleUsers.contains(
                    where: { $0.id == user.id }
                  ) else {
                return
            }
            Task {
                do {
                    try await peopleViewModel.block(user)
                } catch {
                    showsQuickBlockError = true
                }
            }
        }
    }

    private func requestSavedBlockInformation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showsSavedBlockInformation = true
        }
    }

}

struct MessengerChatDestination {
    init?(user: NearbyUser) {}
    func open(using openURL: OpenURLAction) {
        NotificationCenter.default.post(name: .shumOpenChats, object: nil)
    }
}

struct MessengerTransitionRequest: Identifiable {
    let id = UUID()
    let userID: UUID
    let accountGeneration: UUID
    let destination: MessengerChatDestination
}

private struct MessengerTransitionAlertModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @Binding var request: MessengerTransitionRequest?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil },
            set: { isPresented in
                if !isPresented {
                    request = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                Inc.NearbyProfile.messengerTransitionTitle.localized,
                isPresented: isPresented,
                presenting: request
            ) { request in
                Button(Inc.Common.cancel.localized, role: .cancel) { }
                Button(
                    Inc.NearbyProfile.messengerTransitionAlways.localized
                ) {
                    openMessenger(request, always: true)
                }
                Button(Inc.NearbyProfile.messengerTransitionContinue.localized) {
                    openMessenger(request, always: false)
                }
            } message: { _ in
                Text(Inc.NearbyProfile.messengerTransitionMessage.localized)
            }
            .shumOnChange(of: peopleViewModel.accountStateGeneration) { _, _ in
                guard let request,
                      !peopleViewModel.isCurrentAccountStateGeneration(
                        request.accountGeneration
                      ) else { return }
                self.request = nil
            }
    }

    private func openMessenger(
        _ request: MessengerTransitionRequest,
        always: Bool
    ) {
        guard peopleViewModel.isCurrentAccountStateGeneration(
                request.accountGeneration
              ),
              !peopleViewModel.isProfileBlocked(request.userID) else {
            self.request = nil
            return
        }
        if always {
            quickActions.isQuickChatEnabled = true
        }
        request.destination.open(using: openURL)
    }
}

extension View {
    func messengerTransitionAlert(
        request: Binding<MessengerTransitionRequest?>
    ) -> some View {
        modifier(MessengerTransitionAlertModifier(request: request))
    }
}

struct ProfileAvatarButton: View {
    let user: NearbyUser
    let isSaved: Bool
    let cardAction: () -> Void
    let messengerAction: () -> Void
    let blockAction: () -> Void

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                cardAction()
            } label: {
                HStack(spacing: 12) {
                    profileImage
                        .savedProfileAvatarBadge(isSaved: isSaved)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(profileInformation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    NearbyPresenceLabel(
                        user: user,
                        usesCompactCountdown: true,
                        fontSize: 14
                    )
                }
                .frame(maxWidth: .infinity, minHeight: avatarSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(user.name)
            .accessibilityAddTraits(.isButton)

            ProfileMessengerButton(action: messengerAction)
        }
        .frame(maxWidth: .infinity, minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .profileRowContextMenu(
            user: user,
            isSaved: isSaved,
            writeAction: messengerAction,
            blockAction: blockAction
        )
    }

    private var profileInformation: String {
        let bio = user.bio?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return bio.isEmpty
            ? Inc.NearbyProfile.noInformation.localized
            : bio
    }

    @ViewBuilder
    private var profileImage: some View {
        Group {
            if let url = user.photoURL,
               let imageURL = URL(string: url) {
                LocalAvatar(imageURL)
                    .placeholder {
                        ShumInitialsAvatar(name: user.name, size: avatarSize)
                    }
                    .resizable()
                    .scaledToFill()
            } else {
                ShumInitialsAvatar(name: user.name, size: avatarSize)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
    }
}

extension View {
    func savedProfileAvatarBadge(isSaved: Bool) -> some View {
        modifier(SavedProfileAvatarBadgeModifier(isSaved: isSaved))
    }
}

private struct SavedProfileAvatarBadgeModifier: ViewModifier {
    let isSaved: Bool

    func body(content: Content) -> some View {
        content
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        if isSaved {
                            Circle()
                                .frame(width: 18, height: 18)
                                .offset(x: 2, y: 2)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                if isSaved {
                    SavedProfileAvatarBadge()
                }
            }
    }
}

private struct SavedProfileAvatarBadge: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .offset(x: 2, y: 2)
    }
}

struct ProfileMessengerButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Inc.NearbyProfile.messengerChat.localized)
    }
}

struct ProfileModerationRequest: Identifiable {
    let id = UUID()
    let user: NearbyUser
    let accountGeneration: UUID
    let waitsForTransientUI: Bool
}

struct ProfileRowContextMenuModifier: ViewModifier {
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @State private var showsSaveInformation = false

    let user: NearbyUser
    let isSaved: Bool
    let lastMetAt: Date?
    let relativeTimeReference: Date?
    let writeAction: () -> Void
    let deleteAction: (() -> Void)?
    let blockAction: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.contextMenu {
                menuContent
            } preview: {
                ProfileRowContextPreview(
                    user: user,
                    isSaved: isSaved,
                    lastMetAt: lastMetAt,
                    relativeTimeReference: relativeTimeReference,
                    countdownSeconds: lastMetAt == nil
                        ? peopleViewModel.disappearanceCountdowns[
                            user.discoveryID
                        ]
                        : nil,
                    distanceMeters: lastMetAt == nil
                        ? peopleViewModel.distances[user.discoveryID]
                        : nil,
                    subtitle: nil
                )
            }
            .savedProfileInformationAlert(
                isPresented: $showsSaveInformation
            )
        } else {
            content.contextMenu {
                menuContent
            }
            .savedProfileInformationAlert(
                isPresented: $showsSaveInformation
            )
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            writeAction()
        } label: {
            Label(
                Inc.NearbyProfile.write.localized,
                systemImage: "paperplane"
            )
            .foregroundStyle(.primary)
        }
        .tint(.primary)

        Button {
            let isNowSaved = savedPeople.toggle(user)
            presentSaveInformationIfNeeded(isNowSaved: isNowSaved)
        } label: {
            Label(
                isSaved
                    ? Inc.EncounterHistory.remove.localized
                    : Inc.EncounterHistory.save.localized,
                systemImage: isSaved ? "heart.slash" : "heart"
            )
            .foregroundStyle(.primary)
        }
        .tint(.primary)

        Divider()

        if let deleteAction {
            Button {
                deleteAction()
            } label: {
                Label(
                    Inc.EncounterHistory.delete.localized,
                    systemImage: "trash"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)

            Divider()
        }

        if isSaved {
            Button {
                blockAction()
            } label: {
                Label(
                    Inc.NearbyProfile.savedBlockAction.localized,
                    systemImage: "lock.fill"
                )
                .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        } else {
            Button(role: .destructive) {
                blockAction()
            } label: {
                Label(
                    Inc.NearbyProfile.block.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
                .foregroundStyle(.red)
            }
            .tint(.red)
        }
    }

    private func presentSaveInformationIfNeeded(isNowSaved: Bool) {
        guard isNowSaved, savedPeople.shouldShowSaveInformation else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard savedPeople.shouldShowSaveInformation else { return }
            showsSaveInformation = true
        }
    }
}

private struct ProfileModerationDialogModifier: ViewModifier {
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @Binding var request: ProfileModerationRequest?
    @State private var activeUser: NearbyUser?
    @State private var generation: UUID?
    @State private var showError = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $activeUser) { user in
                ProfileBlockOptionsSheet(user: user, onClose: { activeUser = nil }, onBlock: {
                    guard generation == peopleViewModel.accountStateGeneration else { activeUser = nil; return }
                    Task { @MainActor in
                        do { try await peopleViewModel.block(user); activeUser = nil }
                        catch { showError = true }
                    }
                })
                .presentationDetents([.height(195)])
                .presentationDragIndicator(.hidden)
            }
            .task(id: request?.id) {
                guard let pending = request else { return }
                if pending.waitsForTransientUI { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled, request?.id == pending.id,
                      peopleViewModel.isCurrentAccountStateGeneration(pending.accountGeneration) else { return }
                generation = pending.accountGeneration
                activeUser = pending.user
            }
            .shumOnChange(of: activeUser?.id) { _, id in
                if id == nil { request = nil }
            }
            .alert(Inc.NearbyProfile.actionFailedTitle.localized, isPresented: $showError) {
                Button(Inc.Common.okey.localized, role: .cancel) { }
            }
    }
}

private struct ProfileBlockOptionsSheet: View {
    let user: NearbyUser
    let onClose: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(Inc.NearbyProfile.blockTitle.localized)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(profileIdentity)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(
                            Color(uiColor: .tertiarySystemFill),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Inc.Common.close.localized)
            }

            VStack(spacing: 0) {
                ProfileBlockOptionRow(
                    title: Inc.NearbyProfile.block.localized,
                    systemImage: "person.crop.circle.badge.xmark",
                    action: onBlock
                )

            }
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let photoURL = user.photoURL,
               let url = URL(string: photoURL) {
                LocalAvatar(url)
                    .placeholder { placeholder }
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ShumInitialsAvatar(name: user.name, size: 44)
    }

    private var profileIdentity: String {
        let username = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return user.name }
        return "\(user.name) · @\(username)"
    }
}

private struct ProfileBlockOptionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 16))

                Spacer()
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func profileRowContextMenu(
        user: NearbyUser,
        isSaved: Bool,
        lastMetAt: Date? = nil,
        relativeTimeReference: Date? = nil,
        writeAction: @escaping () -> Void,
        deleteAction: (() -> Void)? = nil,
        blockAction: @escaping () -> Void
    ) -> some View {
        modifier(
            ProfileRowContextMenuModifier(
                user: user,
                isSaved: isSaved,
                lastMetAt: lastMetAt,
                relativeTimeReference: relativeTimeReference,
                writeAction: writeAction,
                deleteAction: deleteAction,
                blockAction: blockAction
            )
        )
    }

    func profileModerationDialog(
        request: Binding<ProfileModerationRequest?>
    ) -> some View {
        modifier(ProfileModerationDialogModifier(request: request))
    }
}

struct ProfileRowContextPreview: View {
    let user: NearbyUser
    let isSaved: Bool
    let lastMetAt: Date?
    let relativeTimeReference: Date?
    let countdownSeconds: Int?
    let distanceMeters: Int?
    let subtitle: String?

    private let avatarSize: CGFloat = 52
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 10

    private var sourceWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    private var previewWidth: CGFloat {
        min(sourceWidth, max(320, sourceWidth - 32))
    }

    private var previewScale: CGFloat {
        guard sourceWidth > 0 else { return 1 }
        return previewWidth / sourceWidth
    }

    private var sourceHeight: CGFloat {
        avatarSize + verticalPadding * 2
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar
                .savedProfileAvatarBadge(isSaved: isSaved)

            VStack(alignment: .leading, spacing: 3) {
                Text(user.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle ?? profileInformation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailingInformation

            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: sourceWidth, height: sourceHeight)
        .background(
            previewSurfaceColor,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .scaleEffect(previewScale)
        .frame(
            width: previewWidth,
            height: sourceHeight * previewScale
        )
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let photoURL = user.photoURL,
               let imageURL = URL(string: photoURL) {
                LocalAvatar(imageURL)
                    .placeholder { placeholder }
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ShumInitialsAvatar(name: user.name, size: avatarSize)
    }

    @ViewBuilder
    private var trailingInformation: some View {
        if let lastMetAt {
            EncounterRelativeTimeText(
                date: lastMetAt,
                relativeTo: relativeTimeReference ?? Date(),
                includesMetPrefix: true
            )
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let countdownSeconds {
            Text(
                String.localizedStringWithFormat(
                    Inc.Common.countdownSecondsFormat.localized,
                    countdownSeconds
                )
            )
            .font(.system(size: 14))
            .foregroundStyle(.orange)
            .monospacedDigit()
            .lineLimit(1)
        } else if let distanceMeters {
            Text(
                String.localizedStringWithFormat(
                    Inc.Common.distanceMetersFormat.localized,
                    distanceMeters
                )
            )
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var profileInformation: String {
        let bio = user.bio?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return bio.isEmpty
            ? Inc.NearbyProfile.noInformation.localized
            : bio
    }

    private var previewSurfaceColor: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? .tertiarySystemBackground
                    : .systemBackground
            }
        )
    }
}

private struct NearbyPresenceLabel: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    let user: NearbyUser
    var usesCompactCountdown = false
    var fontSize: CGFloat = 12

    var body: some View {
        Group {
            if let seconds = peopleViewModel.disappearanceCountdowns[
                user.discoveryID
            ] {
                Text(
                    String.localizedStringWithFormat(
                        usesCompactCountdown
                            ? Inc.Common.countdownSecondsFormat.localized
                            : Inc.Common.disappearsInSecondsFormat.localized,
                        seconds
                    )
                )
                .foregroundStyle(.orange)
                .monospacedDigit()
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        Inc.Common.signalLostCountdownFormat.localized,
                        seconds
                    )
                )
            } else if let meters = peopleViewModel.distances[
                user.discoveryID
            ] {
                Text(
                    String.localizedStringWithFormat(
                        Inc.Common.distanceMetersFormat.localized,
                        meters
                    )
                )
                .foregroundStyle(.gray)
            }
        }
        .font(.system(size: fontSize))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .layoutPriority(1)
    }
}

struct ProfileSheetView: View {

    @Environment(\.openURL) private var openURL
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var showPhotoPreview = false

    let user: NearbyUser
    var lastMetAt: Date? = nil
    var showsControls = true

    private var imageURL: URL? {
        guard let url = user.photoURL else { return nil }
        return URL(string: url)
    }

    private func openPhotoPreview() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            showPhotoPreview = true
        }
    }

    private var messengerUsername: String? {
        let value = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return value.isEmpty ? nil : value
    }

    private func openMessengerChat() {
        NotificationCenter.default.post(name: .shumOpenChats, object: nil)
    }

    private func profilePhoto(
        imageURL: URL,
        size: CGFloat
    ) -> some View {
        LocalAvatar(imageURL)
            .placeholder {
                profilePlaceholder(size: size)
            }
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .contentShape(Circle())
    }

    private func profilePlaceholder(size: CGFloat) -> some View {
        ShumInitialsAvatar(name: user.name, size: size)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Spacer(minLength: 0)

                GeometryReader { geo in
                    let availableSize = max(
                        0,
                        min(
                            geo.size.width,
                            geo.size.height
                        ) - 24
                    )
                    let maxSize = availableSize * 0.9 * 1.04

                    ShumCardAvatarLayout(size: maxSize, availableWidth: geo.size.width) { size in
                        if let imageURL {
                            profilePhoto(
                                imageURL: imageURL,
                                size: size
                            )
                                .onTapGesture(perform: openPhotoPreview)
                        } else {
                            profilePlaceholder(size: size)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottom
                    )
                    .offset(y: -10)
                }

                VStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .center, spacing: 3) {
                        Text(
                            user.name
                        )
                        .font(.title)
                        .bold()
                        .multilineTextAlignment(.center)
                        .frame(width: 360, alignment: .center)

                        if let messengerUsername {
                            Text("@\(messengerUsername)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(width: 360, alignment: .center)
                        }
                    }
                    .offset(y: -10)

                    Text(profileInformation)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                        .frame(width: 360, alignment: .center)
                        .frame(minHeight: 48, alignment: .center)

                    RegistrationPrimaryButton(
                        title: Inc.NearbyProfile.write.localized,
                        isEnabled: messengerUsername != nil,
                        accentColor: .blue,
                        enabledForegroundColor: .white,
                        action: openMessengerChat
                    )
                    .frame(width: 360)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .shumGeometryGroup()
                .compositingGroup()
            }
            .padding(.top, 60)
            .offset(y: -10)
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if showsControls {
                ProfileSheetControls(
                    user: user,
                    lastMetAt: lastMetAt
                )
            }
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let imageURL {
                FullScreenPhotoView(isPresented: $showPhotoPreview) {
                    LocalAvatar(imageURL)
                        .placeholder { ProgressView() }
                        .resizable()
                        .scaledToFit()
                }
            }
        }
    }

    private var profileInformation: String {
        let bio = user.bio?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return bio.isEmpty
            ? Inc.NearbyProfile.noInformation.localized
            : bio
    }
}

private struct ProfileSheetControls: View {
    @EnvironmentObject var peopleViewModel: PeopleViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @State private var showsSaveInformation = false

    let user: NearbyUser
    let lastMetAt: Date?

    private var isSaved: Bool {
        savedPeople.contains(user.id)
    }

    private var saveButton: some View {
        Button {
            let isNowSaved = savedPeople.toggle(user)
            guard isNowSaved,
                  savedPeople.shouldShowSaveInformation else {
                return
            }
            showsSaveInformation = true
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 44)
                .contentShape(Capsule())
                .shumReplaceSymbolTransition()
        }
        .accessibilityLabel(
            isSaved
                ? Inc.EncounterHistory.remove.localized
                : Inc.EncounterHistory.save.localized
        )
    }

    private var presenceInfo: some View {
        Group {
            if let lastMetAt {
                EncounterRelativeTimeText(
                    date: lastMetAt,
                    relativeTo: Date(),
                    includesMetPrefix: true
                )
                .font(.system(size: 13))
                .foregroundStyle(.gray)
            } else {
                HStack(spacing: 8) {
                    if peopleViewModel.disappearanceCountdowns[
                        user.discoveryID
                    ] == nil {
                        Text(Inc.Common.nearby.localized)
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                    }

                    NearbyPresenceLabel(user: user, fontSize: 13)
                }
            }
        }
        .frame(width: 360, height: 44, alignment: .leading)
    }

    var body: some View {
        ZStack(alignment: .top) {
            presenceInfo

            HStack {
                Spacer()
                saveButton
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .savedProfileInformationAlert(
            isPresented: $showsSaveInformation
        )
    }
}
