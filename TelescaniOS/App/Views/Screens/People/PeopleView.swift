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
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
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

    let user: NearbyUser

    var body: some View {
        ZStack {
            VStack {
                Spacer(minLength: 0)

                if let url = user.photoURL,
                   let imageURL = URL(string: url) {
                    GeometryReader { geo in
                        let maxSize = max(
                            0,
                            min(
                                geo.size.width,
                                geo.size.height
                            ) - 24
                        )

                        let strokeWidth: CGFloat = 6

                        KFImage(imageURL)
                            .placeholder {
                                Image.personCropCircleFill
                                    .resizable()
                                    .foregroundColor(.gray)
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: maxSize,
                                height: maxSize
                            )
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        Color.gray,
                                        lineWidth: strokeWidth
                                    )
                                    .padding(-strokeWidth)
                                    .opacity(0.3)
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                    }
                } else {
                    Image.personCropCircleFill
                        .resizable()
                        .foregroundColor(.gray)
                        .frame(width: 300, height: 300)
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
                    }

                    CopyUsernameField(username: user.username)
                }
            }
            .padding(.top, 60)

            ProfileSheetControls(user: user)
        }
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
            Image.chevronDownCircleFill
                .font(.system(size: 28))
                .foregroundStyle(Color(uiColor: .systemGray3))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
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
                } else {
                    Image.ellipsisCircleFill
                        .font(.system(size: 28))
                        .foregroundStyle(Color(uiColor: .systemGray3))
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
