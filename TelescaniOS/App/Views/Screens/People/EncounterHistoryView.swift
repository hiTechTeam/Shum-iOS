import SwiftUI
import Kingfisher
import UIKit

struct EncounterHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @State private var selectedEncounter: EncounterHistoryEntry?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.Tabs.metTitle.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            peopleViewModel.refreshEncounterHistory()
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
        List(peopleViewModel.encounterHistory) { encounter in
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selectedEncounter = encounter
            } label: {
                EncounterHistoryRow(encounter: encounter)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(
                    top: 4,
                    leading: 16,
                    bottom: 4,
                    trailing: 16
                )
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
    }

}

private struct EncounterHistoryRow: View {
    let encounter: EncounterHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            EncounterHistoryAvatar(user: encounter.user)

            Text(encounter.user.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            EncounterRelativeTimeText(
                date: encounter.lastSeen,
                includesMetPrefix: true
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct EncounterHistoryAvatar: View {
    let user: NearbyUser

    private let size: CGFloat = 40

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
    var includesMetPrefix = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(relativeTo: context.date))
        }
    }

    private func label(relativeTo now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(
            for: min(date, now),
            relativeTo: now
        )

        guard includesMetPrefix else { return relative }
        return String.localizedStringWithFormat(
            Inc.EncounterHistory.lastSeenFormat.localized,
            relative
        )
    }
}
