import SwiftUI
import UIKit

struct EncounterHistoryView: View {
    var onOpenChat: (NearbyUser) -> Void = { _ in }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @State private var selectedEncounter: EncounterHistoryEntry?
    @State private var showsTimeFilter = false
    @AppStorage("peopleEncounterTimeLowerBound")
    private var storedTimeLowerBound: Double = 0
    @AppStorage("peopleEncounterTimeUpperBound")
    private var storedTimeUpperBound: Double = 24

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
            } else if filteredEncounters.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        ContentUnavailableView(
                            Inc.PeopleFilters.timeEmptyTitle.localized,
                            systemImage: "calendar.badge.clock",
                            description: Text(
                                Inc.PeopleFilters.timeEmptyMessage.localized
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
                        ForEach(filteredEncounters) { encounter in
                            ProfileAvatarButton(
                                user: encounter.user,
                                presenceState: presenceState(for: encounter),
                                presentation: .encounterHistory
                            ) {
                                selectedEncounter = encounter
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.always)
                .refreshable {
                    await peopleViewModel.synchronizeBlockedProfiles()
                    peopleViewModel.refreshEncounterHistory()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    showsTimeFilter = true
                } label: {
                    Image(systemName: "arrow.left.and.right")
                }
                .accessibilityLabel(Inc.PeopleFilters.timeTitle.localized)
                .tint(.primary)
            }
        }
        .sheet(item: $selectedEncounter) { encounter in
            ProfileSheetView(
                user: encounter.user,
                lastMetAt: encounter.lastSeen,
                onOpenChat: onOpenChat
            )
            .environmentObject(peopleViewModel)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsTimeFilter) {
            EncounterTimeFilterSheet(timeRange: timeRangeBinding)
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

    private var filteredEncounters: [EncounterHistoryEntry] {
        let now = Date()
        let oldestDate = now.addingTimeInterval(
            -EncounterHistoryPolicy.retention
        )
        let lowerDate = oldestDate.addingTimeInterval(
            timeRange.lowerBound * 60 * 60
        )
        let upperDate = oldestDate.addingTimeInterval(
            timeRange.upperBound * 60 * 60
        )

        return peopleViewModel.encounterHistory.filter { encounter in
            encounter.lastSeen >= lowerDate && encounter.lastSeen <= upperDate
        }
    }

    private func presenceState(
        for encounter: EncounterHistoryEntry
    ) -> NearbyAvatarPresenceState? {
        guard let seconds = peopleViewModel.reappearanceCountdowns[
            encounter.user.discoveryID
        ] else {
            return nil
        }

        return .reappearing(seconds: seconds)
    }

    private var timeRange: ClosedRange<Double> {
        let lowerBound = min(max(storedTimeLowerBound, 0), 24)
        let upperBound = min(max(storedTimeUpperBound, lowerBound), 24)
        return lowerBound...upperBound
    }

    private var timeRangeBinding: Binding<ClosedRange<Double>> {
        Binding(
            get: { timeRange },
            set: { newRange in
                storedTimeLowerBound = min(
                    max(newRange.lowerBound, 0),
                    24
                )
                storedTimeUpperBound = min(
                    max(newRange.upperBound, storedTimeLowerBound),
                    24
                )
            }
        )
    }
}

private struct EncounterTimeFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var timeRange: ClosedRange<Double>

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Text(Inc.PeopleFilters.timeDescription.localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )

                VStack(spacing: 12) {
                    Text(selectionTitle)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity)

                    EncounterTimeRangeSlider(selection: $timeRange)
                        .frame(height: 44)

                    HStack {
                        Text(boundaryTitle(for: timeRange.lowerBound))
                        Spacer()
                        Text(boundaryTitle(for: timeRange.upperBound))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, 70)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .navigationTitle(Inc.PeopleFilters.timeTitle.localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var selectionTitle: String {
        if timeRange.lowerBound == 0, timeRange.upperBound == 24 {
            return Inc.PeopleFilters.timeAll.localized
        }
        if timeRange.lowerBound == 0 {
            return Inc.PeopleFilters.timeFirst.localized
        }
        if timeRange.upperBound == 24 {
            return Inc.PeopleFilters.timeLatest.localized
        }
        return Inc.PeopleFilters.timeSelected.localized
    }

    private func boundaryTitle(for position: Double) -> String {
        if position == 0 {
            return Inc.PeopleFilters.timeOldest.localized
        }
        if position == 24 {
            return Inc.PeopleFilters.timeNow.localized
        }

        let date = Date().addingTimeInterval((position - 24) * 60 * 60)
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct EncounterTimeRangeSlider: View {
    private enum Handle {
        case lower
        case upper
    }

    @Binding var selection: ClosedRange<Double>

    @State private var activeHandle: Handle?

    private let bounds: ClosedRange<Double> = 0...24
    private let step: Double = 1
    private let handleDiameter: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = max(geometry.size.width - handleDiameter, 1)
            let lowerX = xPosition(
                for: selection.lowerBound,
                trackWidth: trackWidth
            )
            let upperX = xPosition(
                for: selection.upperBound,
                trackWidth: trackWidth
            )
            let centerY = geometry.size.height / 2

            ZStack {
                Capsule()
                    .fill(Color(uiColor: .systemGray4))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: max(upperX - lowerX, 4),
                        height: 4
                    )
                    .position(
                        x: (lowerX + upperX) / 2,
                        y: centerY
                    )

                rangeHandle
                    .position(x: lowerX, y: centerY)

                rangeHandle
                    .position(x: upperX, y: centerY)
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "encounterTimeRangeSlider")
            .gesture(rangeGesture(trackWidth: trackWidth))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Inc.PeopleFilters.timeTitle.localized)
        .accessibilityValue(accessibilityValue)
    }

    private var rangeHandle: some View {
        Circle()
            .fill(Color(uiColor: .systemBackground))
            .overlay {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            .frame(width: handleDiameter, height: handleDiameter)
    }

    private func rangeGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named("encounterTimeRangeSlider")
        )
        .onChanged { value in
            let newValue = sliderValue(
                at: value.location.x,
                trackWidth: trackWidth
            )

            if activeHandle == nil {
                let lowerDistance = abs(newValue - selection.lowerBound)
                let upperDistance = abs(newValue - selection.upperBound)
                activeHandle = lowerDistance <= upperDistance ? .lower : .upper
            }

            switch activeHandle {
            case .lower:
                let lowerBound = min(newValue, selection.upperBound)
                selection = lowerBound...selection.upperBound
            case .upper:
                let upperBound = max(newValue, selection.lowerBound)
                selection = selection.lowerBound...upperBound
            case nil:
                break
            }
        }
        .onEnded { _ in
            activeHandle = nil
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func xPosition(
        for value: Double,
        trackWidth: CGFloat
    ) -> CGFloat {
        let progress = (value - bounds.lowerBound) /
            (bounds.upperBound - bounds.lowerBound)
        return handleDiameter / 2 + CGFloat(progress) * trackWidth
    }

    private func sliderValue(
        at xPosition: CGFloat,
        trackWidth: CGFloat
    ) -> Double {
        let progress = min(
            max((xPosition - handleDiameter / 2) / trackWidth, 0),
            1
        )
        let rawValue = bounds.lowerBound + Double(progress) *
            (bounds.upperBound - bounds.lowerBound)
        return (rawValue / step).rounded() * step
    }

    private var accessibilityValue: String {
        "\(Int(selection.lowerBound))–\(Int(selection.upperBound))"
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
