import SwiftUI
import Kingfisher
import UIKit

struct EncounterHistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var selectedEncounter: EncounterHistoryEntry?
    @State private var photoPreviewUser: NearbyUser?
    @State private var showsClearConfirmation = false
    @State private var relativeTimeReference = Date()
    @State private var moderationRequest: ProfileModerationRequest?
    @State private var telegramTransitionRequest: TelegramTransitionRequest?
    @State private var pendingDeletion: EncounterHistoryEntry?
    @State private var showsSavedBlockInformation = false
    @State private var showsQuickBlockError = false

    var body: some View {
        ZStack {
            Color.peopleListBackground
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
        .telegramTransitionAlert(request: $telegramTransitionRequest)
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
        AdaptiveSystemSwipeList(
            items: peopleViewModel.encounterHistory,
            descriptionText: Inc.EncounterHistory.listDescription.localized,
            reloadIdentifier: relativeTimeReference,
            refreshAction: {
                await peopleViewModel.synchronizeBlockedProfiles()
                peopleViewModel.refreshEncounterHistory()
                relativeTimeReference = Date()
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
                },
                blockAction: {
                    if isSaved {
                        requestSavedBlockInformation()
                    } else {
                        moderationRequest = ProfileModerationRequest(
                            user: encounter.user,
                            waitsForTransientUI: false
                        )
                    }
                }
            )
            .environmentObject(peopleViewModel)
        }
    }

    private func openEncounter(_ encounter: EncounterHistoryEntry) {
        guard let destination = TelegramChatDestination(
                user: encounter.user
              ) else {
            selectedEncounter = encounter
            return
        }

        if quickActions.isQuickChatEnabled {
            destination.open(using: openURL)
            return
        }

        telegramTransitionRequest = TelegramTransitionRequest(
            destination: destination
        )
    }

    private func handleSwipeBlock(_ user: NearbyUser) {
        guard quickActions.isQuickBlockEnabled else {
            moderationRequest = ProfileModerationRequest(
                user: user,
                waitsForTransientUI: true
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
    let isSaved: Bool
    let relativeTimeReference: Date
    let action: () -> Void
    let photoAction: () -> Void
    let infoAction: () -> Void
    let deleteAction: () -> Void
    let blockAction: () -> Void

    private let avatarSize: CGFloat = 52

    var body: some View {
        HStack(spacing: 12) {
            Button(action: photoAction) {
                EncounterHistoryAvatar(
                    user: encounter.user,
                    size: avatarSize
                )
                .overlay(alignment: .bottomTrailing) {
                    if isSaved {
                        SavedProfileAvatarBadge()
                    }
                }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .profileRowContextMenu(
            user: encounter.user,
            isSaved: isSaved,
            lastMetAt: encounter.lastSeen,
            relativeTimeReference: relativeTimeReference,
            writeAction: action,
            deleteAction: deleteAction,
            blockAction: blockAction
        )
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
