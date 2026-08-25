import SwiftUI
import Kingfisher
import UIKit

struct PeopleView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 18),
        count: 3
    )

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
                        .modifier(NativeTopScrollEdgeEffect())
                        .scrollBounceBehavior(.always)
                        .refreshable {
                            await peopleViewModel.refreshNearbyPeople()
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 22) {
                            ForEach(peopleViewModel.visibleUsers) { user in
                                ProfileAvatarButton(user: user) {
                                    selectedUser = user
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, gridBottomPadding)
                    }
                    .modifier(NativeTopScrollEdgeEffect())
                    .scrollBounceBehavior(.always)
                    .refreshable {
                        await peopleViewModel.refreshNearbyPeople()
                    }
                }
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
        }
    }

    private var gridBottomPadding: CGFloat {
        if #available(iOS 26.0, *) {
            90
        } else {
            18
        }
    }
}

struct ProfileAvatarButton: View {
    let user: NearbyUser
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        } label: {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let diameter = min(geometry.size.width, geometry.size.height)

                    profileImage(diameter: diameter)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .center
                        )
                }
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Circle())

                Text(user.name)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileAvatarButtonStyle())
        .accessibilityLabel(user.name)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func profileImage(diameter: CGFloat) -> some View {
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
        .frame(width: diameter, height: diameter)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.primary.opacity(0.13), lineWidth: 2)
        }
        .clipped()
    }
}

private struct ProfileAvatarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.68),
                value: configuration.isPressed
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

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var showPhotoPreview = false

    let user: NearbyUser
    var showsNearbyControls = true
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

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            user.name
                        )
                        .font(.title)
                        .bold()

                    }

                    Group {
                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(Inc.NearbyProfile.usernameFallback.localized)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(
                        width: 360,
                        height: 48,
                        alignment: .leading
                    )

                    CopyUsernameField(username: user.username)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .geometryGroup()
                .compositingGroup()
            }
            .padding(.top, 60)

            if showsNearbyControls {
                ProfileSheetControls(user: user, lastMetAt: lastMetAt)
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
        .presentationBackground {
            ProfileSheetBackground(imageURL: imageURL)
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

private struct ProfileSheetControlSurface: ViewModifier {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    private var fallbackBackground: some View {
        if colorScheme == .light {
            Circle()
                .fill(Color(uiColor: .systemGray6))
        } else if reduceTransparency {
            Circle()
                .fill(Color(uiColor: .secondarySystemBackground))
        } else {
            Circle()
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else if colorScheme == .light {
            content
                .background { fallbackBackground }
        } else {
            content
                .background { fallbackBackground }
                .overlay {
                    Circle()
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
    func profileSheetControlSurface() -> some View {
        modifier(ProfileSheetControlSurface())
    }
}

private struct ProfileSheetControls: View {

    private static let telegramMenuIcon: UIImage = {
        guard let source = UIImage(named: "tg-icon"),
              source.size.width > 0,
              source.size.height > 0 else {
            return UIImage()
        }

        let targetSize = CGSize(width: 17, height: 17)
        let scale = min(
            targetSize.width / source.size.width,
            targetSize.height / source.size.height
        )
        let drawSize = CGSize(
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let image = UIGraphicsImageRenderer(size: targetSize).image { _ in
            source.draw(in: drawRect)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

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
    @Environment(\.openURL) private var openURL
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
            Button(action: openTelegramChat) {
                Label {
                    Text(Inc.NearbyProfile.message.localized)
                } icon: {
                    Image(uiImage: Self.telegramMenuIcon)
                }
            }

            Button(role: .destructive) {
                moderationDialog = .report
            } label: {
                Label(
                    Inc.NearbyProfile.report.localized,
                    systemImage: "exclamationmark.bubble"
                )
            }

            Button(role: .destructive) {
                moderationDialog = .block
            } label: {
                Label(
                    Inc.NearbyProfile.block.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
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
            .profileSheetControlSurface()
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(isSubmitting)
        .accessibilityLabel(Inc.NearbyProfile.actions.localized)
    }

    private func openTelegramChat() {
        let username = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return }

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
            return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        openURL(appURL) { accepted in
            guard !accepted else { return }
            openURL(webURL)
        }
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
                moderationMenu
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
