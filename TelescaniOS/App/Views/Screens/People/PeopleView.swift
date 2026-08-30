import SwiftUI
import Kingfisher
import UIKit

struct PeopleView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?
    @State private var photoPreviewUser: NearbyUser?
    @State private var moderationRequest: ProfileModerationRequest?
    @State private var telegramTransitionRequest: TelegramTransitionRequest?
    @State private var showsEncounterHistory = false

    var body: some View {
        ZStack {
            Color.tsBackground
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
                    SystemSwipeList(
                        items: peopleViewModel.visibleUsers,
                        descriptionText: Inc.Scanning.listDescription.localized,
                        refreshAction: {
                            await peopleViewModel.refreshNearbyPeople()
                        },
                        leadingActions: { _ in
                            [
                                .outlinedSave(
                                    title: Inc.EncounterHistory.save.localized
                                )
                            ]
                        },
                        trailingActions: { user in
                            [
                                SystemSwipeAction(
                                    title: Inc.NearbyProfile.block.localized,
                                    systemImage: "person.crop.circle.badge.xmark",
                                    backgroundColor: .systemRed,
                                    style: .destructive,
                                    handler: {
                                        moderationRequest = ProfileModerationRequest(
                                            user: user,
                                            waitsForTransientUI: true
                                        )
                                    }
                                )
                            ]
                        }
                    ) { user in
                        ProfileAvatarButton(
                            user: user,
                            action: { openUser(user) },
                            photoAction: { openPhoto(of: user) },
                            infoAction: { selectedUser = user },
                            blockAction: {
                                moderationRequest = ProfileModerationRequest(
                                    user: user,
                                    waitsForTransientUI: false
                                )
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsEncounterHistory = true
                } label: {
                    EncounterHistoryToolbarIcon(
                        hasEncounters: !peopleViewModel.encounterHistory.isEmpty
                    )
                }
                .accessibilityLabel(Inc.PeopleFilters.historyButton.localized)
            }
        }
        .navigationDestination(isPresented: $showsEncounterHistory) {
            EncounterHistoryView()
                .environmentObject(peopleViewModel)
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
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .nearbyUserPhotoPreview(user: $photoPreviewUser)
        .telegramTransitionAlert(request: $telegramTransitionRequest)
        .profileModerationDialog(request: $moderationRequest)
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
    }

    private func openUser(_ user: NearbyUser) {
        guard let destination = TelegramChatDestination(user: user) else {
            selectedUser = user
            return
        }

        telegramTransitionRequest = TelegramTransitionRequest(
            destination: destination
        )
    }

    private func openPhoto(of user: NearbyUser) {
        guard let photoURL = user.photoURL,
              URL(string: photoURL) != nil else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            photoPreviewUser = user
        }
    }

}

private struct NearbyUserPhotoPreviewModifier: ViewModifier {
    @Binding var user: NearbyUser?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { user != nil },
            set: { isPresented in
                if !isPresented {
                    user = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $user) { selectedUser in
            if let photoURL = selectedUser.photoURL,
               let imageURL = URL(string: photoURL) {
                FullScreenPhotoView(isPresented: isPresented) {
                    KFImage(imageURL)
                        .placeholder { ProgressView() }
                        .resizable()
                        .scaledToFit()
                }
            }
        }
    }
}

extension View {
    func nearbyUserPhotoPreview(
        user: Binding<NearbyUser?>
    ) -> some View {
        modifier(NearbyUserPhotoPreviewModifier(user: user))
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
}

struct TelegramTransitionRequest: Identifiable {
    let id = UUID()
    let destination: TelegramChatDestination
}

private struct TelegramTransitionAlertModifier: ViewModifier {
    @Environment(\.openURL) private var openURL

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
        content.alert(
            Inc.NearbyProfile.telegramTransitionTitle.localized,
            isPresented: isPresented,
            presenting: request
        ) { request in
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.NearbyProfile.telegramTransitionContinue.localized) {
                open(request.destination)
            }
        } message: { _ in
            Text(Inc.NearbyProfile.telegramTransitionMessage.localized)
        }
    }

    private func open(_ destination: TelegramChatDestination) {
        openURL(destination.appURL) { accepted in
            guard !accepted else { return }
            openURL(destination.webURL)
        }
    }
}

extension View {
    func telegramTransitionAlert(
        request: Binding<TelegramTransitionRequest?>
    ) -> some View {
        modifier(TelegramTransitionAlertModifier(request: request))
    }
}

private struct EncounterHistoryToolbarIcon: View {
    let hasEncounters: Bool

    var body: some View {
        Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(hasEncounters ? Color.blue : Color.gray)
            .frame(width: 28, height: 28)
    }
}

struct ProfileAvatarButton: View {
    let user: NearbyUser
    let action: () -> Void
    let photoAction: () -> Void
    let infoAction: () -> Void
    let blockAction: () -> Void

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                photoAction()
            } label: {
                profileImage
            }
            .buttonStyle(.plain)
            .disabled(!hasPhoto)
            .accessibilityLabel(Inc.Profile.openPhoto.localized)

            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                action()
            } label: {
                HStack(spacing: 12) {
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

            ProfileInfoButton(action: infoAction)
        }
        .frame(maxWidth: .infinity, minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .profileRowContextMenu(
            user: user,
            writeAction: action,
            blockAction: blockAction
        )
    }

    private var hasPhoto: Bool {
        guard let photoURL = user.photoURL else { return false }
        return URL(string: photoURL) != nil
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

struct ProfileInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(
                    Color.secondary.opacity(0.14),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Inc.NearbyProfile.openCard.localized)
    }
}

struct ProfileModerationRequest: Identifiable {
    let id = UUID()
    let user: NearbyUser
    let waitsForTransientUI: Bool
}

struct ProfileRowContextMenuModifier: ViewModifier {
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    let user: NearbyUser
    let lastMetAt: Date?
    let relativeTimeReference: Date?
    let writeAction: () -> Void
    let deleteAction: (() -> Void)?
    let blockAction: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Group {
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

                    Divider()

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

                    if let deleteAction {
                        Divider()

                        Button(role: .destructive) {
                            deleteAction()
                        } label: {
                            Label(
                                Inc.EncounterHistory.delete.localized,
                                systemImage: "trash"
                            )
                            .foregroundStyle(.red)
                        }
                        .tint(.red)
                    }
                }
            } preview: {
                ProfileRowContextPreview(
                    user: user,
                    lastMetAt: lastMetAt,
                    relativeTimeReference: relativeTimeReference,
                    countdownSeconds: lastMetAt == nil
                        ? peopleViewModel.disappearanceCountdowns[
                            user.discoveryID
                        ]
                        : nil,
                    distanceMeters: lastMetAt == nil
                        ? peopleViewModel.distances[user.discoveryID]
                        : nil
                )
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
                    reportDetails = ""
                    if !isSubmitting {
                        activeUser = nil
                        presentationToken = nil
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
            Inc.NearbyProfile.reportDetailsMessage.localized
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
                activeUser = request.user
                presentationToken = token

                guard request.waitsForTransientUI else {
                    showsBlockOptions = true
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard presentationToken == token,
                          activeUser != nil,
                          !isSubmitting else { return }
                    showsBlockOptions = true
                }
            }
    }

    @ViewBuilder
    private var moderationAlertActions: some View {
        switch moderationAlert {
        case .reportConfirmation:
            TextField(
                Inc.NearbyProfile.reportDetailsPlaceholder.localized,
                text: $reportDetails
            )
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.NearbyProfile.reportSend.localized, role: .destructive) {
                submitReportAndBlock()
            }
            .disabled(
                reportDetails.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        case .error:
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        case nil:
            EmptyView()
        }
    }

    private func openReport() {
        isOpeningReport = true
        showsBlockOptions = false
        reportDetails = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard activeUser != nil else {
                isOpeningReport = false
                return
            }
            moderationAlert = .reportConfirmation
            isOpeningReport = false
        }
    }

    private func submitReportAndBlock() {
        guard let user = activeUser else { return }
        let details = reportDetails.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isSubmitting = true
        Task {
            do {
                try await peopleViewModel.submitReport(
                    for: user,
                    reason: .other,
                    details: details.isEmpty ? nil : details
                )
            } catch {
                // Blocking remains the primary safety action even if the
                // report request cannot be delivered.
            }

            do {
                try await peopleViewModel.block(user)
                isSubmitting = false
                reportDetails = ""
                activeUser = nil
                presentationToken = nil
            } catch {
                isSubmitting = false
                moderationAlert = .error
            }
        }
    }

    private func submitBlock() {
        guard let user = activeUser else { return }
        showsBlockOptions = false
        isSubmitting = true
        Task {
            do {
                try await peopleViewModel.block(user)
                isSubmitting = false
                activeUser = nil
                presentationToken = nil
            } catch {
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
        presentationToken = nil
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
        lastMetAt: Date? = nil,
        relativeTimeReference: Date? = nil,
        writeAction: @escaping () -> Void,
        deleteAction: (() -> Void)? = nil,
        blockAction: @escaping () -> Void
    ) -> some View {
        modifier(
            ProfileRowContextMenuModifier(
                user: user,
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

private struct ProfileRowContextPreview: View {
    let user: NearbyUser
    let lastMetAt: Date?
    let relativeTimeReference: Date?
    let countdownSeconds: Int?
    let distanceMeters: Int?

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

            trailingInformation

            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(
                    Color.secondary.opacity(0.14),
                    in: Circle()
                )
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(width: sourceWidth, height: sourceHeight)
        .background(
            Color(
                uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? .tertiarySystemBackground
                        : .systemBackground
                }
            ),
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

            ProfileSheetControls(
                user: user,
                lastMetAt: lastMetAt
            )
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

    let user: NearbyUser
    let lastMetAt: Date?

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
        presenceInfo
        .padding(.top, 8)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
    }
}
