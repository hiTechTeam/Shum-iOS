import SwiftUI
import Kingfisher

struct PeopleView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?

    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                if coordinator.isScaning {
                    List {
                        if peopleViewModel.visibleUsers.isEmpty {
                            VStack(
                                alignment: .leading,
                                spacing: 12
                            ) {
                                Image.wave3Up
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(.gray)

                                Text(Inc.Scanning.noPeopleNeaby.localized)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.gray)
                            }
                            .padding(.top, 12)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 0,
                                    leading: 16,
                                    bottom: 0,
                                    trailing: 16
                                )
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(
                            peopleViewModel.visibleUsers
                        ) { user in
                            Button {
                                selectedUser = user
                            } label: {
                                PeopleRowContent(user: user)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
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
}

struct PeopleRowContent: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    let user: NearbyUser

    var body: some View {
        HStack(spacing: 12) {
            if let url = user.photoURL,
               let imageURL = URL(string: url) {
                KFImage(imageURL)
                    .placeholder {
                        Image.personCropCircleFill
                            .resizable()
                            .foregroundColor(.gray)
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())
                    .clipped()
            } else {
                Image.personCropCircleFill
                    .resizable()
                    .foregroundColor(.gray)
                    .frame(width: 56, height: 56)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    user.name
                )
                .foregroundColor(.gray)
                .font(.system(size: 14))

                Text(
                    user.username
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
            }

            Spacer()

            NearbyPresenceLabel(user: user, usesCompactCountdown: true)
                .padding(.trailing, 20)
        }
    }
}

private struct NearbyPresenceLabel: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    let user: NearbyUser
    var usesCompactCountdown = false

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
        .font(.system(size: 12))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .layoutPriority(1)
    }
}

struct ProfileSheetView: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var showPhotoPreview = false

    let user: NearbyUser

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

                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            user.name
                        )
                        .font(.title)
                        .bold()

                        HStack(spacing: 8) {
                            if peopleViewModel.disappearanceCountdowns[
                                user.discoveryID
                            ] == nil {
                                Text(Inc.Common.nearby.localized)
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                            }

                            NearbyPresenceLabel(user: user)
                        }

                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    CopyUsernameField(username: user.username)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .geometryGroup()
            }
            .padding(.top, 60)

            ProfileSheetControls(user: user)
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
                .blur(radius: 44, opaque: true)
                .saturation(1.22)
                .contrast(0.96)
                .opacity(0.60)

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
                .opacity(0.55)
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

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .profileSheetControlSurface()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Inc.NearbyProfile.close.localized)
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
        HStack {
            closeButton

            Spacer()

            moderationMenu
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
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
