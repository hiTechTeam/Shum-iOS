import SwiftUI
import Kingfisher
import UIKit

struct PeopleView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?
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
                    List(peopleViewModel.visibleUsers) { user in
                        ProfileAvatarButton(user: user) {
                            selectedUser = user
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: 16,
                                bottom: 8,
                                trailing: 16
                            )
                        )
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await peopleViewModel.refreshNearbyPeople()
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
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    peopleViewModel.refreshEncounterHistory()
                    showsEncounterHistory = true
                } label: {
                    EncounterHistoryToolbarIcon(
                        hasEncounters: !peopleViewModel.encounterHistory.isEmpty
                    )
                }
                .accessibilityLabel(Inc.PeopleFilters.historyButton.localized)
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
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsEncounterHistory) {
            EncounterHistorySheet()
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
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

    private let avatarSize: CGFloat = 52

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                profileImage

                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let bio = user.bio?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !bio.isEmpty {
                        Text(bio)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
            VStack {
                Spacer(minLength: 0)

                GeometryReader { geo in
                    let maxSize = max(
                        0,
                        min(
                            geo.size.width,
                            geo.size.height
                        ) - 24
                    )

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
                        maxHeight: .infinity
                    )
                }

                Spacer()

                VStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .center, spacing: 12) {
                        Text(
                            user.name
                        )
                        .font(.title)
                        .bold()
                        .multilineTextAlignment(.center)
                        .frame(width: 360, alignment: .center)

                    }

                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                            .frame(width: 360, alignment: .center)
                            .frame(minHeight: 48, alignment: .center)
                    } else {
                        Color.clear
                            .frame(width: 360, height: 48)
                    }

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
        .modifier(ProfileSheetPresentationBackground(imageURL: imageURL))
    }
}

private struct ProfileSheetPresentationBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    let imageURL: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *),
           colorScheme != .dark || imageURL == nil || reduceTransparency {
            content
        } else {
            content.presentationBackground {
                ProfileSheetBackground(imageURL: imageURL)
            }
        }
    }
}

private struct ProfileSheetBackground: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let imageURL: URL?

    private var systemBackground: Color {
        Color(uiColor: .systemBackground)
    }

    private var photoBlurRadius: CGFloat {
        if #available(iOS 26.0, *) {
            return 44
        }

        return 58
    }

    private var photoSaturation: Double {
        if #available(iOS 26.0, *) {
            return 1.22
        }

        return 1.06
    }

    private var photoOpacity: Double {
        if #available(iOS 26.0, *) {
            return 0.60
        }

        return 0.32
    }

    var body: some View {
        Group {
            if let imageURL,
               colorScheme == .dark,
               !reduceTransparency {
                photoBackground(imageURL: imageURL)
            } else {
                systemBackground
            }
        }
        .ignoresSafeArea()
    }

    private func photoBackground(imageURL: URL) -> some View {
        ZStack {
            systemBackground

            KFImage(imageURL)
                .placeholder { systemBackground }
                .resizable()
                .scaledToFill()
                .scaleEffect(1.35)
                .blur(radius: photoBlurRadius, opaque: true)
                .saturation(photoSaturation)
                .contrast(0.96)
                .opacity(photoOpacity)

            adaptiveMaterial

            LinearGradient(
                stops: [
                    .init(
                        color: systemBackground.opacity(0.08),
                        location: 0
                    ),
                    .init(
                        color: systemBackground.opacity(0.34),
                        location: 0.58
                    ),
                    .init(
                        color: systemBackground.opacity(0.74),
                        location: 1
                    )
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    @ViewBuilder
    private var adaptiveMaterial: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.20)
        }
    }
}

private struct ProfileSheetActionGroupSurface: ViewModifier {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    private var fallbackBackground: some View {
        if colorScheme == .light {
            Capsule()
                .fill(Color(uiColor: .systemGray6))
        } else if reduceTransparency {
            Capsule()
                .fill(Color(uiColor: .secondarySystemBackground))
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else if colorScheme == .light {
            content
                .background { fallbackBackground }
        } else {
            content
                .background { fallbackBackground }
                .overlay {
                    Capsule()
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.24)
                                : Color.black.opacity(0.10),
                            lineWidth: 0.75
                        )
                }
                .shadow(
                    color: Color.black.opacity(
                        colorScheme == .dark ? 0.28 : 0.14
                    ),
                    radius: 4,
                    y: 2
                )
        }
    }
}

private extension View {
    func profileSheetActionGroupSurface() -> some View {
        modifier(ProfileSheetActionGroupSurface())
    }
}

private struct ProfileSheetControls: View {

    private enum ModerationDialog {
        case report
        case block
    }

    private enum ModerationAlert: Identifiable {
        case reportConfirmation(ReportReason)
        case reportSent
        case error

        var id: String {
            switch self {
            case .reportConfirmation(let reason):
                "report-confirmation-\(reason.rawValue)"
            case .reportSent:
                "report-sent"
            case .error:
                "error"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    let user: NearbyUser
    let lastMetAt: Date?

    @State private var moderationDialog: ModerationDialog?
    @State private var moderationAlert: ModerationAlert?
    @State private var reportDetails = ""
    @State private var isSubmitting = false

    private var isModerationDialogPresented: Binding<Bool> {
        Binding(
            get: { moderationDialog != nil },
            set: { isPresented in
                if !isPresented {
                    moderationDialog = nil
                }
            }
        )
    }

    private var moderationDialogTitle: String {
        switch moderationDialog {
        case .report:
            Inc.NearbyProfile.reportTitle.localized
        case .block:
            Inc.NearbyProfile.blockTitle.localized
        case nil:
            ""
        }
    }

    private var moderationDialogMessage: String {
        switch moderationDialog {
        case .report:
            Inc.NearbyProfile.reportMessage.localized
        case .block:
            Inc.NearbyProfile.blockMessage.localized
        case nil:
            ""
        }
    }

    private var isModerationAlertPresented: Binding<Bool> {
        Binding(
            get: { moderationAlert != nil },
            set: { isPresented in
                if !isPresented {
                    moderationAlert = nil
                    reportDetails = ""
                }
            }
        )
    }

    private var moderationAlertTitle: String {
        switch moderationAlert {
        case .reportConfirmation:
            Inc.NearbyProfile.reportConfirmTitle.localized
        case .reportSent:
            Inc.NearbyProfile.reportSentTitle.localized
        case .error:
            Inc.NearbyProfile.actionFailedTitle.localized
        case nil:
            ""
        }
    }

    private var moderationAlertMessage: String {
        switch moderationAlert {
        case .reportConfirmation(let reason):
            String.localizedStringWithFormat(
                Inc.NearbyProfile.reportConfirmMessage.localized,
                reportReasonTitle(reason)
            )
        case .reportSent:
            Inc.NearbyProfile.reportSentMessage.localized
        case .error:
            Inc.NearbyProfile.actionFailedMessage.localized
        case nil:
            ""
        }
    }

    private var moderationMenu: some View {
        Menu {
            Button(role: .destructive) {
                moderationDialog = .report
            } label: {
                Label(
                    Inc.NearbyProfile.report.localized,
                    systemImage: "exclamationmark.bubble"
                )
                .foregroundStyle(.red)
            }
            .tint(.red)

            Button(role: .destructive) {
                moderationDialog = .block
            } label: {
                Label(
                    Inc.NearbyProfile.block.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
                .foregroundStyle(.red)
            }
            .tint(.red)
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(.primary)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(isSubmitting)
        .accessibilityLabel(Inc.NearbyProfile.actions.localized)
    }

    private var actionGroup: some View {
        HStack(spacing: 0) {
            moderationMenu
        }
        .padding(4)
        .profileSheetActionGroupSurface()
    }

    private var presenceInfo: some View {
        Group {
            if let lastMetAt {
                EncounterRelativeTimeText(
                    date: lastMetAt,
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

    @ViewBuilder
    private var moderationDialogActions: some View {
        switch moderationDialog {
        case .report:
            Button(Inc.NearbyProfile.reportSpam.localized) {
                confirmReport(.spam)
            }
            Button(Inc.NearbyProfile.reportHarassment.localized) {
                confirmReport(.harassment)
            }
            Button(Inc.NearbyProfile.reportInappropriate.localized) {
                confirmReport(.inappropriate)
            }
            Button(Inc.NearbyProfile.reportImpersonation.localized) {
                confirmReport(.impersonation)
            }
            Button(Inc.NearbyProfile.reportOther.localized) {
                confirmReport(.other)
            }
            Button(Inc.Common.cancel.localized, role: .cancel) { }
        case .block:
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.NearbyProfile.blockConfirm.localized, role: .destructive) {
                submitBlock()
            }
        case nil:
            EmptyView()
        }
    }

    private func confirmReport(_ reason: ReportReason) {
        moderationDialog = nil
        reportDetails = ""
        moderationAlert = .reportConfirmation(reason)
    }

    private func submitReport(reason: ReportReason) {
        let details = reportDetails
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        Task {
            do {
                try await peopleViewModel.submitReport(
                    for: user,
                    reason: reason,
                    details: details.isEmpty ? nil : details
                )
                isSubmitting = false
                reportDetails = ""
                moderationAlert = .reportSent
            } catch {
                isSubmitting = false
                moderationAlert = .error
            }
        }
    }

    private func submitBlock() {
        moderationDialog = nil
        isSubmitting = true
        Task {
            do {
                try await peopleViewModel.block(user)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                moderationAlert = .error
            }
        }
    }

    private func reportReasonTitle(_ reason: ReportReason) -> String {
        switch reason {
        case .spam:
            Inc.NearbyProfile.reportSpam.localized
        case .harassment:
            Inc.NearbyProfile.reportHarassment.localized
        case .inappropriate:
            Inc.NearbyProfile.reportInappropriate.localized
        case .impersonation:
            Inc.NearbyProfile.reportImpersonation.localized
        case .other:
            Inc.NearbyProfile.reportOther.localized
        }
    }

    @ViewBuilder
    private var moderationAlertActions: some View {
        switch moderationAlert {
        case .reportConfirmation(let reason):
            TextField(
                Inc.NearbyProfile.reportDetailsPlaceholder.localized,
                text: $reportDetails
            )
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.NearbyProfile.reportSend.localized, role: .destructive) {
                submitReport(reason: reason)
            }
        case .reportSent, .error:
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        case nil:
            EmptyView()
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            presenceInfo

            HStack {
                Spacer()
                actionGroup
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .confirmationDialog(
            moderationDialogTitle,
            isPresented: isModerationDialogPresented,
            titleVisibility: .visible
        ) {
            moderationDialogActions
        } message: {
            Text(moderationDialogMessage)
        }
        .alert(
            moderationAlertTitle,
            isPresented: isModerationAlertPresented
        ) {
            moderationAlertActions
        } message: {
            Text(moderationAlertMessage)
        }
    }
}
