import SwiftUI

struct BlockedProfilesView: View {
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var isWorking = false
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name ?? profile.username ?? "—")
                                    .font(.body)
                                if let username = profile.username {
                                    Text(username.hasPrefix("@") ? username : "@\(username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button(Inc.NearbyProfile.unblock.localized) {
                                unblock(profile)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color(uiColor: .systemBlue))
                            .disabled(isWorking)
                        }
                        .padding(12)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 13)
                        )
                        .listRowInsets(
                            EdgeInsets(
                                top: 6,
                                leading: 16,
                                bottom: 6,
                                trailing: 16
                            )
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(Inc.NearbyProfile.blockedProfiles.localized)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isWorking {
                    ProgressView()
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        isWorking = true
        Task {
            do {
                try await peopleViewModel.unblock(profile)
            } catch {
                showError = true
            }
            isWorking = false
        }
    }
}
