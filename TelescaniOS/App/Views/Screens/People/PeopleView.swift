import SwiftUI
import Kingfisher
import UIKit

struct PeopleView: View {
    var onOpenChat: (NearbyUser) -> Void = { _ in }

    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?
    @State private var showsDistanceFilter = false
    @AppStorage("peopleNearbyMaximumDistance")
    private var maximumDistance = NearbyDistanceFilter.maximum

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
                        .scrollBounceBehavior(.always)
                        .refreshable {
                            await peopleViewModel.refreshNearbyPeople()
                        }
                    }
                } else if filteredUsers.isEmpty {
                    GeometryReader { geometry in
                        ScrollView {
                            ContentUnavailableView(
                                Inc.PeopleFilters.nearbyEmptyTitle.localized,
                                systemImage: "ruler",
                                description: Text(
                                    Inc.PeopleFilters.nearbyEmptyMessage.localized
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
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 22) {
                            ForEach(filteredUsers) { user in
                                ProfileAvatarButton(
                                    user: user,
                                    presenceState: presenceState(for: user)
                                ) {
                                    selectedUser = user
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                    }
                    .scrollBounceBehavior(.always)
                    .refreshable {
                        await peopleViewModel.refreshNearbyPeople()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    showsDistanceFilter = true
                } label: {
                    Image(systemName: "ruler")
                }
                .accessibilityLabel(
                    Inc.PeopleFilters.distanceTitle.localized
                )
                .tint(.primary)
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
            ProfileSheetView(user: user, onOpenChat: onOpenChat)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsDistanceFilter) {
            NearbyDistanceFilterSheet(
                maximumDistance: $maximumDistance
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
        }
    }

    private var filteredUsers: [NearbyUser] {
        guard maximumDistance < NearbyDistanceFilter.maximum else {
            return peopleViewModel.visibleUsers
        }

        return peopleViewModel.visibleUsers.filter { user in
            guard let distance = peopleViewModel.distances[
                user.discoveryID
            ] else {
                return false
            }
            return distance <= Int(maximumDistance)
        }
    }

    private func presenceState(
        for user: NearbyUser
    ) -> NearbyAvatarPresenceState {
        guard let seconds = peopleViewModel.disappearanceCountdowns[
            user.discoveryID
        ] else {
            return .active
        }

        return .disappearing(seconds: seconds)
    }
}

private enum NearbyDistanceFilter {
    static let minimum: Double = 10
    static let maximum: Double = 100
    static let step: Double = 10
    static let range = minimum...maximum
}

private struct NearbyDistanceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var maximumDistance: Double

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Text(Inc.PeopleFilters.distanceDescription.localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )

                VStack(spacing: 14) {
                    Text(selectionTitle)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)

                    Slider(
                        value: $maximumDistance,
                        in: NearbyDistanceFilter.range,
                        step: NearbyDistanceFilter.step
                    )
                    .tint(.accentColor)

                    HStack {
                        Text(
                            String.localizedStringWithFormat(
                                Inc.Common.distanceMetersFormat.localized,
                                Int(NearbyDistanceFilter.minimum)
                            )
                        )
                        Spacer()
                        Text(Inc.PeopleFilters.maximum.localized)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, 70)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .navigationTitle(Inc.PeopleFilters.distanceTitle.localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var selectionTitle: String {
        guard maximumDistance < NearbyDistanceFilter.maximum else {
            return Inc.PeopleFilters.distanceUnlimited.localized
        }

        return String.localizedStringWithFormat(
            Inc.PeopleFilters.distanceValueFormat.localized,
            Int(maximumDistance)
        )
    }
}

enum NearbyAvatarPresenceState {
    case active
    case disappearing(seconds: Int)
    case reappearing(seconds: Int)
}

enum ProfileAvatarPresentation: Equatable {
    case nearby
    case encounterHistory

    var scale: CGFloat {
        switch self {
        case .nearby:
            return 1
        case .encounterHistory:
            return 0.8
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .nearby:
            return 2
        case .encounterHistory:
            return 3
        }
    }

    var borderColor: Color {
        switch self {
        case .nearby:
            return Color.primary.opacity(0.13)
        case .encounterHistory:
            return Color(uiColor: .systemGray).opacity(0.48)
        }
    }
}

struct ProfileAvatarButton: View {
    let user: NearbyUser
    let presenceState: NearbyAvatarPresenceState?
    let presentation: ProfileAvatarPresentation
    let action: () -> Void

    init(
        user: NearbyUser,
        presenceState: NearbyAvatarPresenceState? = nil,
        presentation: ProfileAvatarPresentation = .nearby,
        action: @escaping () -> Void
    ) {
        self.user = user
        self.presenceState = presenceState
        self.presentation = presentation
        self.action = action
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        } label: {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    let diameter = min(
                        geometry.size.width,
                        geometry.size.height
                    ) * presentation.scale

                    profileImage(diameter: diameter)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .center
                        )
                }
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Circle())

                VStack(spacing: 2) {
                    Text(user.name)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if let reappearingSeconds {
                        Text(
                            "\(Inc.Common.nearby.localized) · "
                                + String.localizedStringWithFormat(
                                    Inc.Common.countdownSecondsFormat.localized,
                                    reappearingSeconds
                                )
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileAvatarButtonStyle())
        .accessibilityLabel(user.name)
        .accessibilityAddTraits(.isButton)
    }

    private var reappearingSeconds: Int? {
        guard let presenceState,
              case let .reappearing(seconds) = presenceState else {
            return nil
        }
        return seconds
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
            if let presenceState {
                NearbyAvatarPresenceRing(state: presenceState)
            } else if presentation == .encounterHistory {
                Circle()
                    .strokeBorder(
                        presentation.borderColor,
                        lineWidth: presentation.borderWidth
                    )
                    .padding(-presentation.borderWidth)
            } else {
                Circle()
                    .strokeBorder(
                        presentation.borderColor,
                        lineWidth: presentation.borderWidth
                    )
            }
        }
    }
}

private struct NearbyAvatarPresenceRing: View {
    let state: NearbyAvatarPresenceState

    private let lineWidth: CGFloat = 3

    var body: some View {
        Group {
            switch state {
            case .active:
                Circle()
                    .strokeBorder(Color.primary.opacity(0.13), lineWidth: 2)

            case .disappearing:
                Circle()
                    .trim(from: 0, to: remainingProgress)
                    .stroke(
                        Color.orange,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)

            case .reappearing:
                Circle()
                    .trim(from: 0, to: remainingProgress)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            }
        }
        .animation(
            .linear(duration: BLEPresencePolicy.countdownUpdateInterval),
            value: remainingProgress
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var remainingProgress: CGFloat {
        let seconds: Int
        let countdownDuration: TimeInterval

        switch state {
        case .active:
            return 1
        case .disappearing(let remainingSeconds):
            seconds = remainingSeconds
            countdownDuration = BLEPresencePolicy.transitionCountdownDuration
        case .reappearing(let remainingSeconds):
            seconds = remainingSeconds
            countdownDuration = BLEPresencePolicy.transitionCountdownDuration
        }

        return min(
            max(CGFloat(Double(seconds) / countdownDuration), 0),
            1
        )
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

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var showPhotoPreview = false

    let user: NearbyUser
    var lastMetAt: Date? = nil
    var onOpenChat: (NearbyUser) -> Void = { _ in }

    private var imageURL: URL? {
        guard let url = user.photoURL else { return nil }
        return URL(string: url)
    }

    private var telegramUsername: String? {
        let value = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "@")
        )
        return handle.isEmpty ? nil : value
    }

    private func openPhotoPreview() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            showPhotoPreview = true
        }
    }

    private func openInternalChat() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onOpenChat(user)
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

                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 360, alignment: .leading)
                            .frame(minHeight: 48, alignment: .leading)
                    } else {
                        Color.clear
                            .frame(width: 360, height: 48)
                    }

                    VStack(spacing: 7) {
                        RegistrationPrimaryButton(
                            title: Inc.NearbyProfile.write.localized,
                            accentColor: .blue,
                            action: openInternalChat
                        )
                        .frame(width: 360)

                        Text(
                            telegramUsername == nil
                                ? Inc.NearbyProfile.internalChatHint.localized
                                : Inc.NearbyProfile.telegramChatHint.localized
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 360)
                    }
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

    private var telegramUsername: String? {
        let value = user.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "@")
        )
        return handle.isEmpty ? nil : value
    }

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

    private var telegramChatButton: some View {
        Button(action: openTelegramChat) {
            Image(uiImage: Self.telegramMenuIcon)
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Inc.NearbyProfile.telegramChat.localized)
    }

    private var actionGroup: some View {
        HStack(spacing: 0) {
            if telegramUsername != nil {
                telegramChatButton
            }

            moderationMenu
        }
        .padding(4)
        .profileSheetActionGroupSurface()
    }

    private func openTelegramChat() {
        guard let telegramUsername else { return }
        let username = telegramUsername
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
            if let seconds = peopleViewModel.reappearanceCountdowns[
                user.discoveryID
            ] {
                HStack(spacing: 6) {
                    Text(Inc.Common.nearby.localized)
                    Text(
                        String.localizedStringWithFormat(
                            Inc.Common.countdownSecondsFormat.localized,
                            seconds
                        )
                    )
                    .monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            } else if let lastMetAt {
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
