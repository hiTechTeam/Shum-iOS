import SwiftUI
import Kingfisher

struct BlockedProfilesView: View {
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var profileBeingUnblocked: UUID?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if peopleViewModel.blockedProfiles.isEmpty {
                    ContentUnavailableView(
                        Inc.NearbyProfile.noBlockedProfiles.localized,
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                } else {
                    List(peopleViewModel.blockedProfiles) { profile in
                        HStack(spacing: 12) {
                            BlockedProfileAvatar(profile: profile)

                            Text(profile.name ?? profile.username ?? "—")
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            if profileBeingUnblocked == profile.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 44)
                            } else {
                                Button(Inc.NearbyProfile.unblock.localized) {
                                    unblock(profile)
                                }
                                .buttonStyle(.borderless)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .disabled(profileBeingUnblocked != nil)
                            }
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: 16,
                                bottom: 8,
                                trailing: 16
                            )
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.NearbyProfile.blockedProfiles.localized)
                        .telescanSheetTitleStyle()
                }
            }
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
        }
        .alert(
            Inc.NearbyProfile.actionFailedTitle.localized,
            isPresented: $showError
        ) {
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.actionFailedMessage.localized)
        }
    }

    private func unblock(_ profile: BlockedProfileResponse) {
        guard profileBeingUnblocked == nil else { return }
        profileBeingUnblocked = profile.id
        Task {
            do {
                try await peopleViewModel.unblock(profile)
            } catch {
                showError = true
            }
            profileBeingUnblocked = nil
        }
    }
}

private struct BlockedProfileAvatar: View {
    let profile: BlockedProfileResponse

    private let size: CGFloat = 44

    var body: some View {
        Group {
            if let photoURL = profile.photoUrl,
               let url = URL(string: photoURL) {
                KFImage(url)
                    .placeholder { placeholder }
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Circle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }
    }
}

struct SavedProfilesView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedUser: NearbyUser?
    @State private var telegramTransitionRequest: TelegramTransitionRequest?

    private var visibleSavedUsers: [NearbyUser] {
        savedPeople.users.filter { !peopleViewModel.isProfileBlocked($0.id) }
    }

    var body: some View {
        ZStack {
            Color.peopleListBackground.ignoresSafeArea()

            if visibleSavedUsers.isEmpty {
                ContentUnavailableView(
                    Inc.NearbyProfile.noSavedProfiles.localized,
                    systemImage: "heart"
                )
            } else {
                AdaptiveSystemSwipeList(
                    items: visibleSavedUsers,
                    descriptionText: Inc.NearbyProfile.savedListDescription
                        .localized,
                    showsRowSeparators: true,
                    refreshAction: { },
                    trailingActions: { user, _ in
                        [
                            SystemSwipeAction(
                                title: Inc.EncounterHistory.remove.localized,
                                systemImage: "heart.slash",
                                backgroundColor: .systemGray,
                                style: .destructive,
                                handler: {
                                    UIImpactFeedbackGenerator(
                                        style: .light
                                    ).impactOccurred()
                                    withAnimation {
                                        savedPeople.remove(user)
                                    }
                                }
                            )
                        ]
                    }
                ) { user, _ in
                    SavedProfileRow(
                        user: user,
                        cardAction: { openInfo(for: user) },
                        telegramAction: { openUser(user) },
                        removeAction: {
                            withAnimation {
                                savedPeople.remove(user)
                            }
                        }
                    )
                }
            }
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user, showsControls: false)
                .environmentObject(peopleViewModel)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .telegramTransitionAlert(request: $telegramTransitionRequest)
        .onChange(of: peopleViewModel.blockedProfiles.map(\.id)) { _, _ in
            closeBlockedProfileSurfaces()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(Inc.NearbyProfile.savedProfiles.localized)
                    .telescanSheetTitleStyle()
            }
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
        } else {
            telegramTransitionRequest = TelegramTransitionRequest(
                userID: user.id,
                accountGeneration: peopleViewModel.accountStateGeneration,
                destination: destination
            )
        }
    }

    private func openInfo(for user: NearbyUser) {
        guard !peopleViewModel.isProfileBlocked(user.id) else { return }
        selectedUser = user
    }

    private func closeBlockedProfileSurfaces() {
        if let selectedUser,
           peopleViewModel.isProfileBlocked(selectedUser.id) {
            self.selectedUser = nil
        }
        telegramTransitionRequest = nil
    }
}

private struct SavedProfileRow: View {
    let user: NearbyUser
    let cardAction: () -> Void
    let telegramAction: () -> Void
    let removeAction: () -> Void

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button(action: cardAction) {
                HStack(spacing: 12) {
                    SavedProfileAvatar(user: user, size: avatarSize)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(user.username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: avatarSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(user.name)

            ProfileTelegramButton(action: telegramAction)
        }
        .frame(maxWidth: .infinity, minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button(action: telegramAction) {
                Label(
                    Inc.NearbyProfile.write.localized,
                    systemImage: "paperplane"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)

            Divider()

            Button(action: removeAction) {
                Label(
                    Inc.EncounterHistory.remove.localized,
                    systemImage: "heart.slash"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)
        } preview: {
            ProfileRowContextPreview(
                user: user,
                isSaved: false,
                lastMetAt: nil,
                relativeTimeReference: nil,
                countdownSeconds: nil,
                distanceMeters: nil,
                subtitle: user.username
            )
        }
    }

}

private struct SavedProfileAvatar: View {
    let user: NearbyUser
    var size: CGFloat = 44

    var body: some View {
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
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Circle()
            .fill(Color(uiColor: .tertiarySystemFill))
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }
    }
}
