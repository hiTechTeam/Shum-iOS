import SwiftUI
import Kingfisher

struct EncounterHistoryTab: View {
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    var body: some View {
        NavigationStack {
            EncounterHistoryView()
                .navigationTitle(Inc.Tabs.metTitle.localized)
                .navigationBarTitleDisplayMode(.large)
        }
        .tabItem {
            Label(
                Inc.Tabs.metTitle.localized,
                systemImage: "clock.arrow.circlepath"
            )
        }
        .tag(SelectedTab.met)
        .badge(peopleViewModel.encounterHistory.count)
    }
}

private struct EncounterHistoryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var selectedEncounter: EncounterHistoryEntry?
    @State private var showsClearConfirmation = false

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
                List(peopleViewModel.encounterHistory) { encounter in
                    Button {
                        selectedEncounter = encounter
                    } label: {
                        EncounterHistoryRow(encounter: encounter)
                    }
                    .listRowBackground(
                        Color(uiColor: .systemOrange).opacity(0.20)
                    )
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await peopleViewModel.synchronizeBlockedProfiles()
                    peopleViewModel.refreshEncounterHistory()
                }
            }
        }
        .toolbar {
            if !peopleViewModel.encounterHistory.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        Inc.EncounterHistory.clear.localized,
                        systemImage: "trash"
                    ) {
                        showsClearConfirmation = true
                    }
                    .accessibilityLabel(
                        Inc.EncounterHistory.clear.localized
                    )
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
        .alert(
            Inc.EncounterHistory.clearTitle.localized,
            isPresented: $showsClearConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                Inc.EncounterHistory.clear.localized,
                role: .destructive
            ) {
                peopleViewModel.clearEncounterHistory()
            }
        } message: {
            Text(Inc.EncounterHistory.clearMessage.localized)
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

private struct EncounterHistoryRow: View {
    let encounter: EncounterHistoryEntry

    private var user: NearbyUser {
        encounter.user
    }

    var body: some View {
        HStack(spacing: 12) {
            profileImage

            VStack(alignment: .leading, spacing: 4) {
                Text(user.name)
                    .foregroundStyle(.gray)
                    .font(.system(size: 14))
                    .lineLimit(1)

                Text(user.username)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBlue))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            EncounterRelativeTimeText(date: encounter.lastSeen)
                .font(.system(size: 12))
                .foregroundStyle(.gray)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var profileImage: some View {
        if let photoURL = user.photoURL,
           let imageURL = URL(string: photoURL) {
            KFImage(imageURL)
                .placeholder {
                    Image.personCropCircleFill
                        .resizable()
                        .foregroundStyle(.gray)
                }
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 62)
                .clipShape(Circle())
                .clipped()
        } else {
            Image.personCropCircleFill
                .resizable()
                .foregroundStyle(.gray)
                .frame(width: 56, height: 56)
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
