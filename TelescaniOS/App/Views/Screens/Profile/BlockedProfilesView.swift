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
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if savedPeople.users.isEmpty {
                    ContentUnavailableView(
                        Inc.NearbyProfile.noSavedProfiles.localized,
                        systemImage: "heart"
                    )
                } else {
                    List(savedPeople.users) { user in
                        HStack(spacing: 12) {
                            SavedProfileAvatar(user: user)

                            Text(user.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            Button(Inc.EncounterHistory.remove.localized) {
                                UIImpactFeedbackGenerator(
                                    style: .light
                                ).impactOccurred()
                                savedPeople.remove(user)
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
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
                    Text(Inc.NearbyProfile.savedProfiles.localized)
                        .telescanSheetTitleStyle()
                }
            }
        }
    }
}

private struct SavedProfileAvatar: View {
    let user: NearbyUser

    private let size: CGFloat = 44

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
