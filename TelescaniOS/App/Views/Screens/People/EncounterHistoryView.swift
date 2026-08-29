import SwiftUI
import Kingfisher
import UIKit

struct EncounterHistoryView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @State private var selectedEncounter: EncounterHistoryEntry?
    @State private var photoPreviewUser: NearbyUser?
    @State private var showsClearConfirmation = false
    @State private var relativeTimeReference = Date()

    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()

            if peopleViewModel.encounterHistory.isEmpty {
                ContentUnavailableView(
                    Inc.EncounterHistory.emptyTitle.localized,
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        Inc.EncounterHistory.emptyMessage.localized
                    )
                )
            } else {
                encounterList
            }
        }
        .navigationTitle(Inc.Tabs.metTitle.localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(peopleViewModel.encounterHistory.isEmpty)
                .accessibilityLabel(Inc.EncounterHistory.clear.localized)
            }
        }
        .sheet(item: $selectedEncounter) { encounter in
            ProfileSheetView(
                user: encounter.user,
                lastMetAt: encounter.lastSeen
            )
            .environmentObject(peopleViewModel)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .nearbyUserPhotoPreview(user: $photoPreviewUser)
        .alert(
            Inc.EncounterHistory.clearTitle.localized,
            isPresented: $showsClearConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(Inc.EncounterHistory.clear.localized, role: .destructive) {
                peopleViewModel.clearEncounterHistory()
            }
        } message: {
            Text(Inc.EncounterHistory.clearMessage.localized)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            peopleViewModel.refreshEncounterHistory()
            relativeTimeReference = Date()
        }
        .onChange(of: peopleViewModel.encounterHistory.map(\.id)) { _, ids in
            if let selectedEncounter,
               !ids.contains(selectedEncounter.id) {
                self.selectedEncounter = nil
            }
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
    }

    private var encounterList: some View {
        List {
            Text(Inc.EncounterHistory.listDescription.localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .listRowInsets(
                    EdgeInsets(
                        top: 10,
                        leading: 16,
                        bottom: 10,
                        trailing: 16
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(peopleViewModel.encounterHistory) { encounter in
                EncounterHistoryRow(
                    encounter: encounter,
                    relativeTimeReference: relativeTimeReference,
                    action: {
                        UIImpactFeedbackGenerator(
                            style: .light
                        ).impactOccurred()
                        openEncounter(encounter)
                    },
                    photoAction: {
                        openPhoto(of: encounter.user)
                    },
                    infoAction: {
                        selectedEncounter = encounter
                    },
                    deleteAction: {
                        deleteEncounter(encounter)
                    }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(
                    EdgeInsets(
                        top: 8,
                        leading: 16,
                        bottom: 8,
                        trailing: 16
                    )
                )
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .refreshable {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
            relativeTimeReference = Date()
        }
    }

    private func openEncounter(_ encounter: EncounterHistoryEntry) {
        guard let destination = TelegramChatDestination(
                user: encounter.user
              ) else {
            selectedEncounter = encounter
            return
        }

        openURL(destination.appURL) { accepted in
            guard !accepted else { return }
            openURL(destination.webURL)
        }
    }

    private func deleteEncounter(_ encounter: EncounterHistoryEntry) {
        withAnimation {
            peopleViewModel.removeEncounterFromHistory(encounter.user)
        }
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

private struct EncounterHistoryRow: View {
    let encounter: EncounterHistoryEntry
    let relativeTimeReference: Date
    let action: () -> Void
    let photoAction: () -> Void
    let infoAction: () -> Void
    let deleteAction: () -> Void

    @State private var moderationRequest: ProfileRowModerationRequest?

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button(action: photoAction) {
                EncounterHistoryAvatar(
                    user: encounter.user,
                    size: avatarSize
                )
            }
            .buttonStyle(.plain)
            .disabled(!hasPhoto)
            .accessibilityLabel(Inc.Profile.openPhoto.localized)

            Button(action: action) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(encounter.user.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(profileInformation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    EncounterRelativeTimeText(
                        date: encounter.lastSeen,
                        relativeTo: relativeTimeReference,
                        includesMetPrefix: true
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: avatarSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(encounter.user.name)

            ProfileInfoButton(action: infoAction)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: avatarSize)
        .profileRowContextMenu(
            user: encounter.user,
            lastMetAt: encounter.lastSeen,
            relativeTimeReference: relativeTimeReference,
            writeAction: action,
            deleteAction: deleteAction,
            moderationRequest: $moderationRequest
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                deleteAction()
            } label: {
                Label(
                    Inc.EncounterHistory.delete.localized,
                    systemImage: "trash"
                )
            }
            .tint(.gray)

            Button(role: .destructive) {
                moderationRequest = .block
            } label: {
                Label(
                    Inc.NearbyProfile.block.localized,
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
            .tint(.red)
        }
    }

    private var hasPhoto: Bool {
        guard let photoURL = encounter.user.photoURL else { return false }
        return URL(string: photoURL) != nil
    }

    private var profileInformation: String {
        let bio = encounter.user.bio?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return bio.isEmpty
            ? Inc.NearbyProfile.noInformation.localized
            : bio
    }
}

private struct EncounterHistoryAvatar: View {
    let user: NearbyUser
    let size: CGFloat

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
    }

    private var placeholder: some View {
        Image.personCropCircleFill
            .resizable()
            .scaledToFit()
            .foregroundStyle(.gray)
    }
}

struct EncounterRelativeTimeText: View {
    let date: Date
    let relativeTo: Date
    var includesMetPrefix = false

    var body: some View {
        Text(label(relativeTo: relativeTo))
    }

    private func label(relativeTo now: Date) -> String {
        let calendar = Calendar.current
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        if dayDifference == 1 {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateStyle = .medium
            formatter.doesRelativeDateFormatting = true
            return formatted(formatter.string(from: date))
        }

        if dayDifference != 0 {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateStyle = .medium
            return formatted(formatter.string(from: date))
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(
            for: min(date, now),
            relativeTo: now
        )

        return formatted(relative)
    }

    private func formatted(_ value: String) -> String {
        guard includesMetPrefix else { return value }
        return String.localizedStringWithFormat(
            Inc.EncounterHistory.lastSeenFormat.localized,
            value
        )
    }
}
