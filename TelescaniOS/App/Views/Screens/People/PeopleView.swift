import SwiftUI
import Kingfisher
import UIKit

struct PeopleView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedUser: NearbyUser?
    @State private var moderationRequest: ProfileModerationRequest?
    @State private var telegramTransitionRequest: TelegramTransitionRequest?
    @State private var showsSavedBlockInformation = false
    @State private var showsQuickBlockError = false

    var body: some View {
        ZStack {
            Color.peopleListBackground
                .ignoresSafeArea()

            if coordinator.isScaning {
                if peopleViewModel.visibleUsers.isEmpty {
                    GeometryReader { geometry in
                        ScrollView {
                            ContentUnavailableView(
                                Inc.Scanning.emptyTitle.localized,
                                systemImage: "wave.3.up",
                                description: Text(
                                    Inc.Scanning.noPeopleNeaby.localized
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        }
                        .scrollBounceBehavior(.always)
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
                            telegramAction: { openUser(user) },
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
                ContentUnavailableView(
                    Inc.Scanning.scanning.localized,
                    systemImage: "eye.slash",
                    description: Text(
                        Inc.Scanning.turnedOffScanning.localized
                    )
                )
            }
        }
        .onChange(of: scenePhase) {  _, newPhase in
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
        .onChange(of: peopleViewModel.visibleUsers.map(\.id)) { _, ids in
            if let selectedUser, !ids.contains(selectedUser.id) {
                self.selectedUser = nil
            }
            if let moderationRequest,
               !ids.contains(moderationRequest.user.id) {
                self.moderationRequest = nil
            }
            if let telegramTransitionRequest,
               !ids.contains(telegramTransitionRequest.userID) {
                self.telegramTransitionRequest = nil
            }
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .telegramTransitionAlert(request: $telegramTransitionRequest)
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
        guard let destination = TelegramChatDestination(user: user) else {
            selectedUser = user
            return
        }

        if quickActions.isQuickChatEnabled {
            destination.open(using: openURL)
            return
        }

        telegramTransitionRequest = TelegramTransitionRequest(
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

struct TelegramChatDestination {
    let appURL: URL
    let webURL: URL

    init?(user: NearbyUser) {
        let username = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return nil }

        var appComponents = URLComponents()
        appComponents.scheme = "tg"
        appComponents.host = "resolve"
        appComponents.queryItems = [
            URLQueryItem(name: "domain", value: username)
        ]

        var webComponents = URLComponents()
        webComponents.scheme = "https"
        webComponents.host = "t.me"
        webComponents.path = "/\(username)"

        guard let appURL = appComponents.url,
              let webURL = webComponents.url else {
            return nil
        }

        self.appURL = appURL
        self.webURL = webURL
    }

    func open(using openURL: OpenURLAction) {
        openURL(appURL) { accepted in
            guard !accepted else { return }
            openURL(webURL)
        }
    }
}

struct TelegramTransitionRequest: Identifiable {
    let id = UUID()
    let userID: UUID
    let accountGeneration: UUID
    let destination: TelegramChatDestination
}

private struct TelegramTransitionAlertModifier: ViewModifier {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @Binding var request: TelegramTransitionRequest?

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
                Inc.NearbyProfile.telegramTransitionTitle.localized,
                isPresented: isPresented,
                presenting: request
            ) { request in
                Button(Inc.Common.cancel.localized, role: .cancel) { }
                Button(
                    Inc.NearbyProfile.telegramTransitionAlways.localized
                ) {
                    openTelegram(request, always: true)
                }
                Button(Inc.NearbyProfile.telegramTransitionContinue.localized) {
                    openTelegram(request, always: false)
                }
            } message: { _ in
                Text(Inc.NearbyProfile.telegramTransitionMessage.localized)
            }
            .onChange(of: peopleViewModel.accountStateGeneration) { _, _ in
                guard let request,
                      !peopleViewModel.isCurrentAccountStateGeneration(
                        request.accountGeneration
                      ) else { return }
                self.request = nil
            }
    }

    private func openTelegram(
        _ request: TelegramTransitionRequest,
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
    func telegramTransitionAlert(
        request: Binding<TelegramTransitionRequest?>
    ) -> some View {
        modifier(TelegramTransitionAlertModifier(request: request))
    }
}

struct ProfileAvatarButton: View {
    let user: NearbyUser
    let isSaved: Bool
    let cardAction: () -> Void
    let telegramAction: () -> Void
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
                        .overlay(alignment: .bottomTrailing) {
                            if isSaved {
                                SavedProfileAvatarBadge()
                            }
                        }

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

            ProfileTelegramButton(action: telegramAction)
        }
        .frame(maxWidth: .infinity, minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .profileRowContextMenu(
            user: user,
            isSaved: isSaved,
            writeAction: telegramAction,
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
                KFImage(imageURL)
                    .placeholder {
                        Image.personCropCircleFill
                            .resizable()
                            .foregroundStyle(.gray)
                    }
                    .resizable()
                    .scaledToFill()
            } else {
                Image.personCropCircleFill
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
    }
}

struct SavedProfileAvatarBadge: View {
    @Environment(\.profileRowSurfaceColor) private var surfaceColor

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .background(surfaceColor, in: Circle())
            .offset(x: 2, y: 2)
    }
}

struct ProfileTelegramButton: View {
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
        .accessibilityLabel(Inc.NearbyProfile.telegramChat.localized)
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
    private enum ModerationAlert: Identifiable {
        case reportConfirmation
        case error

        var id: String {
            switch self {
            case .reportConfirmation:
                "report-confirmation"
            case .error:
                "error"
            }
        }
    }

    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @Binding var request: ProfileModerationRequest?

    @State private var activeUser: NearbyUser?
    @State private var showsBlockOptions = false
    @State private var moderationAlert: ModerationAlert?
    @State private var reportDetails = ""
    @State private var isSubmitting = false
    @State private var isOpeningReport = false
    @State private var presentationToken: UUID?
    @State private var activeAccountGeneration: UUID?
    @State private var reportRequestID: UUID?
    @State private var hasSubmittedReport = false

    private var reportDetailsBinding: Binding<String> {
        Binding(
            get: { reportDetails },
            set: {
                reportDetails = String(
                    $0.prefix(ReportCommentPolicy.maximumLength)
                )
            }
        )
    }

    private var isBlockDialogPresented: Binding<Bool> {
        Binding(
            get: { showsBlockOptions },
            set: { isPresented in
                showsBlockOptions = isPresented
                if !isPresented,
                   moderationAlert == nil,
                   !isSubmitting,
                   !isOpeningReport {
                    activeUser = nil
                    activeAccountGeneration = nil
                    presentationToken = nil
                }
            }
        )
    }

    private var isModerationAlertPresented: Binding<Bool> {
        Binding(
            get: { moderationAlert != nil },
            set: { isPresented in
                if !isPresented {
                    moderationAlert = nil
                    if !isSubmitting {
                        activeUser = nil
                        activeAccountGeneration = nil
                        presentationToken = nil
                        reportDetails = ""
                        reportRequestID = nil
                        hasSubmittedReport = false
                    }
                }
            }
        )
    }

    private var moderationAlertTitle: String {
        switch moderationAlert {
        case .reportConfirmation:
            Inc.NearbyProfile.reportConfirmTitle.localized
        case .error:
            Inc.NearbyProfile.actionFailedTitle.localized
        case nil:
            ""
        }
    }

    private var moderationAlertMessage: String {
        switch moderationAlert {
        case .reportConfirmation:
            "\(Inc.NearbyProfile.reportDetailsMessage.localized)\n"
                + "\(reportDetails.count)/"
                + "\(ReportCommentPolicy.maximumLength)"
        case .error:
            Inc.NearbyProfile.actionFailedMessage.localized
        case nil:
            ""
        }
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: isBlockDialogPresented) {
                if let activeUser {
                    ProfileBlockOptionsSheet(
                        user: activeUser,
                        onClose: cancel,
                        onBlock: submitBlock,
                        onReport: openReport
                    )
                    .presentationDetents([.height(250)])
                    .presentationDragIndicator(.hidden)
                }
            }
            .alert(
                moderationAlertTitle,
                isPresented: isModerationAlertPresented
            ) {
                moderationAlertActions
            } message: {
                Text(moderationAlertMessage)
            }
            .onChange(of: request?.id) { _, _ in
                guard let request else { return }
                let token = request.id
                self.request = nil
                guard peopleViewModel.isCurrentAccountStateGeneration(
                    request.accountGeneration
                ) else {
                    cancel()
                    return
                }
                activeUser = request.user
                activeAccountGeneration = request.accountGeneration
                presentationToken = token
                reportDetails = ""
                reportRequestID = nil
                hasSubmittedReport = false

                guard request.waitsForTransientUI else {
                    showsBlockOptions = true
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard presentationToken == token,
                          activeUser != nil,
                          peopleViewModel.isCurrentAccountStateGeneration(
                            request.accountGeneration
                          ),
                          !isSubmitting else { return }
                    showsBlockOptions = true
                }
            }
            .onChange(of: peopleViewModel.blockedProfiles.map(\.id)) { _, _ in
                guard let activeUser,
                      peopleViewModel.isProfileBlocked(activeUser.id) else {
                    return
                }
                cancel()
            }
            .onChange(of: peopleViewModel.accountStateGeneration) { _, newValue in
                guard let activeAccountGeneration,
                      activeAccountGeneration != newValue else { return }
                cancel()
            }
    }

    @ViewBuilder
    private var moderationAlertActions: some View {
        switch moderationAlert {
        case .reportConfirmation:
            TextField(
                Inc.NearbyProfile.reportDetailsPlaceholder.localized,
                text: reportDetailsBinding
            )
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.NearbyProfile.reportSend.localized, role: .destructive) {
                submitReportAndBlock()
            }
        case .error:
            Button(Inc.Common.cancel.localized, role: .cancel) {
                cancel()
            }
            Button(Inc.NearbyProfile.retry.localized) {
                retryFailedOperation()
            }
        case nil:
            EmptyView()
        }
    }

    private func openReport() {
        isOpeningReport = true
        showsBlockOptions = false
        reportDetails = ""
        reportRequestID = UUID()
        hasSubmittedReport = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard activeUser != nil,
                  let activeAccountGeneration,
                  peopleViewModel.isCurrentAccountStateGeneration(
                    activeAccountGeneration
                  ) else {
                isOpeningReport = false
                cancel()
                return
            }
            moderationAlert = .reportConfirmation
            isOpeningReport = false
        }
    }

    private func submitReportAndBlock() {
        guard let user = activeUser,
              let activeAccountGeneration,
              peopleViewModel.isCurrentAccountStateGeneration(
                activeAccountGeneration
              ) else {
            cancel()
            return
        }
        let requestID = reportRequestID ?? UUID()
        reportRequestID = requestID
        let details = reportDetails
        isSubmitting = true
        Task {
            if !hasSubmittedReport {
                do {
                    try await peopleViewModel.submitReport(
                        for: user,
                        details: details,
                        requestID: requestID
                    )
                    hasSubmittedReport = true
                } catch {
                    guard peopleViewModel.isCurrentAccountStateGeneration(
                        activeAccountGeneration
                    ) else {
                        isSubmitting = false
                        cancel()
                        return
                    }
                    isSubmitting = false
                    moderationAlert = .error
                    return
                }
            }

            guard peopleViewModel.isCurrentAccountStateGeneration(
                activeAccountGeneration
            ) else {
                isSubmitting = false
                cancel()
                return
            }
            do {
                try await peopleViewModel.block(user)
                isSubmitting = false
                reportDetails = ""
                activeUser = nil
                self.activeAccountGeneration = nil
                presentationToken = nil
                reportRequestID = nil
                hasSubmittedReport = false
            } catch {
                guard peopleViewModel.isCurrentAccountStateGeneration(
                    activeAccountGeneration
                ) else {
                    isSubmitting = false
                    cancel()
                    return
                }
                isSubmitting = false
                moderationAlert = .error
            }
        }
    }

    private func retryFailedOperation() {
        moderationAlert = nil
        if reportRequestID != nil {
            submitReportAndBlock()
        } else {
            submitBlock()
        }
    }

    private func submitBlock() {
        guard let user = activeUser,
              let activeAccountGeneration,
              peopleViewModel.isCurrentAccountStateGeneration(
                activeAccountGeneration
              ) else {
            cancel()
            return
        }
        showsBlockOptions = false
        isSubmitting = true
        Task {
            do {
                try await peopleViewModel.block(user)
                isSubmitting = false
                activeUser = nil
                self.activeAccountGeneration = nil
                presentationToken = nil
                reportRequestID = nil
                hasSubmittedReport = false
            } catch {
                guard peopleViewModel.isCurrentAccountStateGeneration(
                    activeAccountGeneration
                ) else {
                    isSubmitting = false
                    cancel()
                    return
                }
                isSubmitting = false
                moderationAlert = .error
            }
        }
    }

    private func cancel() {
        showsBlockOptions = false
        moderationAlert = nil
        reportDetails = ""
        isOpeningReport = false
        activeUser = nil
        activeAccountGeneration = nil
        presentationToken = nil
        reportRequestID = nil
        hasSubmittedReport = false
    }
}

private struct ProfileBlockOptionsSheet: View {
    let user: NearbyUser
    let onClose: () -> Void
    let onBlock: () -> Void
    let onReport: () -> Void

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
                    title: Inc.NearbyProfile.blockWithoutReport.localized,
                    systemImage: "person.crop.circle.badge.xmark",
                    action: onBlock
                )

                Divider()
                    .padding(.leading, 58)

                ProfileBlockOptionRow(
                    title: Inc.NearbyProfile.reportSend.localized,
                    systemImage: "exclamationmark.bubble",
                    action: onReport
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
                KFImage(url)
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
        Image.personCropCircleFill
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
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
                .overlay(alignment: .bottomTrailing) {
                    if isSaved {
                        SavedProfileAvatarBadge()
                    }
                }

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

            Image(systemName: "info.circle")
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: sourceWidth, height: sourceHeight)
        .background(
            previewSurfaceColor,
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .environment(\.profileRowSurfaceColor, previewSurfaceColor)
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
                KFImage(imageURL)
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
        Image.personCropCircleFill
            .resizable()
            .scaledToFit()
            .foregroundStyle(.gray)
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

    private var telegramUsername: String? {
        let value = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return value.isEmpty ? nil : value
    }

    private func openTelegramChat() {
        guard let telegramUsername else { return }

        var appComponents = URLComponents()
        appComponents.scheme = "tg"
        appComponents.host = "resolve"
        appComponents.queryItems = [
            URLQueryItem(name: "domain", value: telegramUsername)
        ]

        var webComponents = URLComponents()
        webComponents.scheme = "https"
        webComponents.host = "t.me"
        webComponents.path = "/\(telegramUsername)"

        guard let appURL = appComponents.url,
              let webURL = webComponents.url else {
            return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        openURL(appURL) { accepted in
            guard !accepted else { return }
            openURL(webURL)
        }
    }

    private func profilePhoto(
        imageURL: URL,
        size: CGFloat
    ) -> some View {
        KFImage(imageURL)
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
        Image.personCropCircleFill
            .resizable()
            .scaledToFit()
            .foregroundColor(.gray)
            .frame(width: size, height: size)
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

                    Group {
                        if let imageURL {
                            profilePhoto(
                                imageURL: imageURL,
                                size: maxSize
                            )
                                .onTapGesture(perform: openPhotoPreview)
                        } else {
                            profilePlaceholder(size: maxSize)
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

                        if let telegramUsername {
                            Text("@\(telegramUsername)")
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
                        isEnabled: telegramUsername != nil,
                        accentColor: .blue,
                        action: openTelegramChat
                    )
                    .frame(width: 360)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .geometryGroup()
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
                    KFImage(imageURL)
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
                .contentTransition(.symbolEffect(.replace))
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
