import SwiftUI
import UIKit

struct EncounterHistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedEncounter: EncounterHistoryEntry?
    @State private var showsClearConfirmation = false
    @State private var relativeTimeReference = Date()
    @State private var moderationRequest: ProfileModerationRequest?
    @State private var messengerTransitionRequest: MessengerTransitionRequest?
    @State private var pendingDeletion: EncounterHistoryEntry?
    @State private var showsSavedBlockInformation = false
    @State private var showsQuickBlockError = false
    @State private var highlightedEncounterIDs: Set<UUID> = []

    var body: some View {
        ZStack {
            Color.peopleListBackground
                .ignoresSafeArea()

            if peopleViewModel.encounterHistory.isEmpty {
                ShumContentUnavailableView(
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
        .messengerTransitionAlert(request: $messengerTransitionRequest)
        .profileModerationDialog(request: $moderationRequest)
        .alert(
            Inc.NearbyProfile.savedBlockTitle.localized,
            isPresented: $showsSavedBlockInformation
        ) {
            Button(Inc.NearbyProfile.savedBlockOK.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.savedBlockMessage.localized)
        }
        .alert(
            Inc.NearbyProfile.actionFailedTitle.localized,
            isPresented: $showsQuickBlockError
        ) {
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.actionFailedMessage.localized)
        }
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
        .alert(
            Inc.EncounterHistory.deleteTitle.localized,
            isPresented: deleteConfirmationIsPresented,
            presenting: pendingDeletion
        ) { encounter in
            Button(Inc.Common.cancel.localized, role: .cancel) {
                pendingDeletion = nil
            }
            Button(Inc.EncounterHistory.delete.localized, role: .destructive) {
                deleteEncounter(encounter)
                pendingDeletion = nil
            }
        } message: { _ in
            Text(Inc.EncounterHistory.deleteMessage.localized)
        }
        .shumOnChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            peopleViewModel.refreshEncounterHistory()
            relativeTimeReference = Date()
        }
        .shumOnChange(of: peopleViewModel.encounterHistory.map(\.id)) { _, ids in
            if let selectedEncounter,
               !ids.contains(selectedEncounter.id) {
                self.selectedEncounter = nil
            }
            if let moderationRequest,
               !ids.contains(moderationRequest.user.id) {
                self.moderationRequest = nil
            }
            if let messengerTransitionRequest,
               !ids.contains(messengerTransitionRequest.userID) {
                self.messengerTransitionRequest = nil
            }
            if let pendingDeletion, !ids.contains(pendingDeletion.id) {
                self.pendingDeletion = nil
            }
        }
        .task {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
    }

    private var encounterList: some View {
        AdaptiveSystemSwipeList(
            items: peopleViewModel.encounterHistory,
            descriptionText: Inc.EncounterHistory.listDescription.localized,
            reloadIdentifier: relativeTimeReference,
            refreshAction: {
                await peopleViewModel.synchronizeBlockedProfiles()
                peopleViewModel.refreshEncounterHistory()
                relativeTimeReference = Date()
            },
            rowSurfaceColor: { encounter in
                highlightedEncounterIDs.contains(encounter.id)
                    ? Color.orange.opacity(0.16)
                    : nil
            },
            leadingActions: { _, _ in
                [
                    .save(
                        title: Inc.EncounterHistory.save.localized,
                        removeTitle: Inc.EncounterHistory.remove.localized
                    )
                ]
            },
            trailingActions: { encounter, isSaved in
                let leadingAction = isSaved
                    ? SystemSwipeAction(
                        title: Inc.NearbyProfile.savedBlockAction.localized,
                        systemImage: "lock.fill",
                        backgroundColor: .systemGray,
                        style: .normal,
                        handler: {
                            requestSavedBlockInformation()
                        }
                    )
                    : SystemSwipeAction(
                        title: Inc.NearbyProfile.block.localized,
                        systemImage: "person.crop.circle.badge.xmark",
                        backgroundColor: .systemRed,
                        style: quickActions.isQuickBlockEnabled
                            ? .destructive
                            : .normal,
                        handler: {
                            handleSwipeBlock(encounter.user)
                        }
                    )

                return [
                    leadingAction,
                    SystemSwipeAction(
                        title: Inc.EncounterHistory.delete.localized,
                        systemImage: "trash",
                        backgroundColor: .systemGray,
                        style: .normal,
                        handler: {
                            requestDeleteEncounterAfterSwipe(encounter)
                        }
                    )
                ]
            }
        ) { encounter, isSaved in
            EncounterHistoryRow(
                encounter: encounter,
                isSaved: isSaved,
                relativeTimeReference: relativeTimeReference,
                cardAction: {
                    openInfo(for: encounter)
                },
                messengerAction: {
                    UIImpactFeedbackGenerator(
                        style: .light
                    ).impactOccurred()
                    openEncounter(encounter)
                },
                deleteAction: {
                    deleteEncounter(encounter)
                },
                blockAction: {
                    if isSaved {
                        requestSavedBlockInformation()
                    } else {
                        moderationRequest = ProfileModerationRequest(
                            user: encounter.user,
                            accountGeneration: peopleViewModel
                                .accountStateGeneration,
                            waitsForTransientUI: false
                        )
                    }
                }
            )
            .environmentObject(peopleViewModel)
            .onAppear {
                revealEncounterIfNeeded(encounter)
            }
        }
    }

    private func revealEncounterIfNeeded(
        _ encounter: EncounterHistoryEntry
    ) {
        guard peopleViewModel.unviewedEncounterIDs.contains(encounter.id),
              highlightedEncounterIDs.insert(encounter.id).inserted else {
            return
        }

        peopleViewModel.markEncounterViewed(encounter.id)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            _ = withAnimation(.easeOut(duration: 0.8)) {
                highlightedEncounterIDs.remove(encounter.id)
            }
        }
    }

    private func openEncounter(_ encounter: EncounterHistoryEntry) {
        guard !peopleViewModel.isProfileBlocked(encounter.id) else { return }
        guard let destination = MessengerChatDestination(
                user: encounter.user
              ) else {
            selectedEncounter = encounter
            return
        }

        if quickActions.isQuickChatEnabled {
            destination.open(using: openURL)
            return
        }

        messengerTransitionRequest = MessengerTransitionRequest(
            userID: encounter.id,
            accountGeneration: peopleViewModel.accountStateGeneration,
            destination: destination
        )
    }

    private func openInfo(for encounter: EncounterHistoryEntry) {
        guard !peopleViewModel.isProfileBlocked(encounter.id) else { return }
        selectedEncounter = encounter
    }

    private func handleSwipeBlock(_ user: NearbyUser) {
        guard quickActions.isQuickBlockEnabled else {
            moderationRequest = ProfileModerationRequest(
                user: user,
                accountGeneration: peopleViewModel.accountStateGeneration,
                waitsForTransientUI: true
            )
            return
        }

        let generation = peopleViewModel.accountStateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard peopleViewModel.isCurrentAccountStateGeneration(generation),
                  peopleViewModel.encounterHistory.contains(
                    where: { $0.id == user.id }
                  ) else {
                return
            }
            Task {
                do {
                    try await peopleViewModel.block(user)
                } catch {
                    showsQuickBlockError = true
                }
            }
        }
    }

    private func deleteEncounter(_ encounter: EncounterHistoryEntry) {
        withAnimation {
            peopleViewModel.removeEncounterFromHistory(encounter.user)
        }
    }

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func requestDeleteEncounterAfterSwipe(
        _ encounter: EncounterHistoryEntry
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard peopleViewModel.encounterHistory.contains(
                where: { $0.id == encounter.id }
            ) else {
                return
            }

            if quickActions.isQuickClearEnabled {
                deleteEncounter(encounter)
                return
            }

            pendingDeletion = encounter
        }
    }

    private func requestSavedBlockInformation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showsSavedBlockInformation = true
        }
    }

}

private struct EncounterHistoryRow: View {
    let encounter: EncounterHistoryEntry
    let isSaved: Bool
    let relativeTimeReference: Date
    let cardAction: () -> Void
    let messengerAction: () -> Void
    let deleteAction: () -> Void
    let blockAction: () -> Void

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button(action: cardAction) {
                HStack(spacing: 12) {
                    EncounterHistoryAvatar(
                        user: encounter.user,
                        size: avatarSize
                    )
                    .savedProfileAvatarBadge(isSaved: isSaved)

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

            ProfileMessengerButton(action: messengerAction)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: avatarSize)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .profileRowContextMenu(
            user: encounter.user,
            isSaved: isSaved,
            lastMetAt: encounter.lastSeen,
            relativeTimeReference: relativeTimeReference,
            writeAction: messengerAction,
            deleteAction: deleteAction,
            blockAction: blockAction
        )
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
    }

    private var placeholder: some View {
        ShumInitialsAvatar(name: user.name, size: size)
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
