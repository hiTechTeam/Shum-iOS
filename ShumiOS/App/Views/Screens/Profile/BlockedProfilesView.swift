import SwiftUI

struct BlockedProfilesView: View {
    @ObservedObject var runtime: ShumRuntime
    @Environment(\.colorScheme) private var colorScheme

    @State private var profileBeingUnblocked: String?
    @State private var showError = false

    private var blockedCards: [ShumContactCard] {
        (runtime.permanent?.state.blocked?.values.map { $0 } ?? [])
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if blockedCards.isEmpty {
                    ShumBlockedProfilesEmptyState()
                } else {
                    List(blockedCards) { card in
                        HStack(spacing: 12) {
                            ShumAvatar(
                                name: card.name,
                                size: 44,
                                imageData: runtime.profile(for: card.peerID)?.avatar
                            )

                            Text(card.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            if profileBeingUnblocked == card.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 44)
                            } else {
                                Button(Inc.NearbyProfile.unblock.localized) {
                                    unblock(card)
                                }
                                .buttonStyle(.borderless)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
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
                    .shumGroupedScreenBackground()
                }
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.NearbyProfile.blockedProfiles.localized)
                        .shumSheetTitleStyle()
                }
            }
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

    private func unblock(_ card: ShumContactCard) {
        guard profileBeingUnblocked == nil else { return }
        profileBeingUnblocked = card.id
        Task { @MainActor in
            do {
                try runtime.permanent?.setBlocked(card, blocked: false)
            } catch {
                showError = true
            }
            profileBeingUnblocked = nil
        }
    }
}

private struct ShumBlockedProfilesEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            ShumPixelEmptyIcon(kind: .blocked)
                .foregroundStyle(.primary)
                .frame(width: 88, height: 68)
                .accessibilityHidden(true)

            Text("Никого не заблокировано")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text("Заблокированные пользователи появятся здесь.")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: 330)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

struct SavedProfilesView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedUser: NearbyUser?
    @State private var messengerTransitionRequest: MessengerTransitionRequest?

    private var visibleSavedUsers: [NearbyUser] {
        savedPeople.users.filter { !peopleViewModel.isProfileBlocked($0.id) }
    }

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if visibleSavedUsers.isEmpty {
                ShumContentUnavailableView(
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
                        messengerAction: { openUser(user) },
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
        .messengerTransitionAlert(request: $messengerTransitionRequest)
        .shumOnChange(of: peopleViewModel.blockedProfiles.map(\.id)) { _, _ in
            closeBlockedProfileSurfaces()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(Inc.NearbyProfile.savedProfiles.localized)
                    .shumSheetTitleStyle()
            }
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
        } else {
            messengerTransitionRequest = MessengerTransitionRequest(
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
        messengerTransitionRequest = nil
    }
}

private struct SavedProfileRow: View {
    let user: NearbyUser
    let cardAction: () -> Void
    let messengerAction: () -> Void
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

            ProfileMessengerButton(action: messengerAction)
        }
        .frame(maxWidth: .infinity, minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button(action: messengerAction) {
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
                LocalAvatar(url)
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
        ShumInitialsAvatar(name: user.name, size: size)
    }
}
