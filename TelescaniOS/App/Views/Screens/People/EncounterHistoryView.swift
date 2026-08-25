import SwiftUI

struct EncounterHistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var selectedEncounter: EncounterHistoryEntry?

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 18),
        count: 3
    )

    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()

            if peopleViewModel.encounterHistory.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        ContentUnavailableView(
                            Inc.EncounterHistory.emptyTitle.localized,
                            systemImage: "clock.arrow.circlepath",
                            description: Text(
                                Inc.EncounterHistory.emptyMessage.localized
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.always)
                    .refreshable {
                        await peopleViewModel.synchronizeBlockedProfiles()
                        peopleViewModel.refreshEncounterHistory()
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 22) {
                        ForEach(peopleViewModel.encounterHistory) { encounter in
                            ProfileAvatarButton(user: encounter.user) {
                                selectedEncounter = encounter
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
                .scrollBounceBehavior(.always)
                .refreshable {
                    await peopleViewModel.synchronizeBlockedProfiles()
                    peopleViewModel.refreshEncounterHistory()
                }
            }
        }
        .sheet(item: $selectedEncounter) { encounter in
            ProfileSheetView(
                user: encounter.user,
                lastMetAt: encounter.lastSeen
            )
            .environmentObject(peopleViewModel)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
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
