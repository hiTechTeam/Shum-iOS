import SwiftUI
import UIKit

extension Color {
    static var peopleListBackground: Color {
        return Color(uiColor: .systemBackground)
    }
}

struct SystemSwipeAction {
    struct SavedPresentation {
        let title: String
        let systemImage: String
        let backgroundColor: UIColor
    }

    let title: String
    let systemImage: String
    let backgroundColor: UIColor
    let style: UIContextualAction.Style
    let savedPresentation: SavedPresentation?
    let handler: () -> Void

    init(
        title: String,
        systemImage: String,
        backgroundColor: UIColor,
        style: UIContextualAction.Style,
        savedPresentation: SavedPresentation? = nil,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.backgroundColor = backgroundColor
        self.style = style
        self.savedPresentation = savedPresentation
        self.handler = handler
    }

    static func save(
        title: String,
        removeTitle: String
    ) -> SystemSwipeAction {
        SystemSwipeAction(
            title: title,
            systemImage: "heart",
            backgroundColor: .systemGreen,
            style: .normal,
            savedPresentation: SavedPresentation(
                title: removeTitle,
                systemImage: "heart.slash",
                backgroundColor: .systemGray
            ),
            handler: { }
        )
    }
}

final class SavedPeopleStateStore: ObservableObject {
    static let shared = SavedPeopleStateStore()

    private let identifiersStorageKey = "savedPeopleProfileIDs"
    private let profilesStorageKey = "savedPeopleProfiles"
    @Published private var savedIDs: Set<UUID>
    @Published private(set) var users: [NearbyUser]

    private init() {
        let storedIDs = Set(
            UserDefaults.standard
                .stringArray(forKey: identifiersStorageKey)?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
        let decodedUsers = UserDefaults.standard
            .data(forKey: profilesStorageKey)
            .flatMap { try? JSONDecoder().decode([NearbyUser].self, from: $0) }
            ?? []
        var seenIDs = Set<UUID>()
        let uniqueUsers = decodedUsers.filter {
            seenIDs.insert($0.id).inserted
        }
        users = uniqueUsers
        savedIDs = storedIDs.union(uniqueUsers.map(\.id))
    }

    func contains(_ id: UUID) -> Bool {
        savedIDs.contains(id)
    }

    var count: Int {
        savedIDs.count
    }

    @discardableResult
    func toggle(_ user: NearbyUser) -> Bool {
        let isSaved: Bool

        if savedIDs.remove(user.id) != nil {
            users.removeAll { $0.id == user.id }
            isSaved = false
        } else {
            savedIDs.insert(user.id)
            users.append(user)
            isSaved = true
        }

        persist()
        return isSaved
    }

    func remove(_ user: NearbyUser) {
        guard savedIDs.contains(user.id) else { return }
        _ = toggle(user)
    }

    func refreshProfile(_ user: NearbyUser) {
        guard savedIDs.contains(user.id) else { return }

        if let index = users.firstIndex(where: { $0.id == user.id }) {
            guard users[index] != user else { return }
            users[index] = user
        } else {
            users.append(user)
        }

        persist()
    }

    private func persist() {
        UserDefaults.standard.set(
            savedIDs.map(\.uuidString).sorted(),
            forKey: identifiersStorageKey
        )
        UserDefaults.standard.set(
            try? JSONEncoder().encode(users),
            forKey: profilesStorageKey
        )
    }
}

protocol SavedPeopleListItem: Identifiable where ID == UUID {
    var savedProfile: NearbyUser { get }
}

extension NearbyUser: SavedPeopleListItem {
    var savedProfile: NearbyUser { self }
}

extension EncounterHistoryEntry: SavedPeopleListItem {
    var savedProfile: NearbyUser { user }
}

private struct SavedPeopleRow<Item, RowContent>: View
where Item: SavedPeopleListItem, RowContent: View {
    @ObservedObject var savedPeople: SavedPeopleStateStore

    let item: Item
    let rowContent: (Item, Bool) -> RowContent

    var body: some View {
        rowContent(item, savedPeople.contains(item.id))
    }
}

private struct NativeSwipeInteractionRow<Content: View>: View {
    @State private var isSwipeActive = false

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if #available(iOS 26.0, *) {
                    Color(
                        uiColor: UIColor { traits in
                            traits.userInterfaceStyle == .dark
                                ? .tertiarySystemBackground
                                : .secondarySystemBackground
                        }
                    )
                        .opacity(isSwipeActive ? 1 : 0)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 26,
                                style: .continuous
                            )
                        )

                    NativeSwipeOffsetProbe(isActive: $isSwipeActive)
                        .allowsHitTesting(false)
                }
            }
            .animation(
                .easeOut(duration: isSwipeActive ? 0.16 : 0.5),
                value: isSwipeActive
            )
    }
}

private struct NativeSwipeOffsetProbe: UIViewRepresentable {
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.isActive = $isActive
        context.coordinator.attach(to: view)
    }

    static func dismantleUIView(
        _ view: UIView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        var isActive: Binding<Bool>

        private weak var probeView: UIView?
        private var displayLink: CADisplayLink?
        private var restingOriginX: CGFloat?

        init(isActive: Binding<Bool>) {
            self.isActive = isActive
        }

        func attach(to view: UIView) {
            guard probeView !== view || displayLink == nil else { return }

            stop()
            probeView = view
            restingOriginX = nil

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(observeHorizontalOffset)
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 15,
                maximum: 30,
                preferred: 30
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            restingOriginX = nil
        }

        @objc private func observeHorizontalOffset() {
            guard let probeView,
                  probeView.window != nil,
                  let scrollView = enclosingScrollView(for: probeView) else {
                return
            }

            let originX = probeView.convert(.zero, to: scrollView).x

            guard let restingOriginX else {
                self.restingOriginX = originX
                return
            }

            let offset = abs(originX - restingOriginX)

            if offset > 4 {
                setActive(true)
            } else if offset < 1 {
                self.restingOriginX = originX
                setActive(false)
            }
        }

        private func enclosingScrollView(for view: UIView) -> UIScrollView? {
            sequence(first: view.superview, next: { $0?.superview })
                .compactMap { $0 as? UIScrollView }
                .first
        }

        private func setActive(_ value: Bool) {
            guard isActive.wrappedValue != value else { return }
            isActive.wrappedValue = value
        }
    }
}

struct AdaptiveSystemSwipeList<Item, RowContent>: View
where Item: SavedPeopleListItem & Equatable, RowContent: View {
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared

    let items: [Item]
    let descriptionText: String
    let reloadIdentifier: AnyHashable?
    let refreshAction: () async -> Void
    let leadingActions: (Item, Bool) -> [SystemSwipeAction]
    let trailingActions: (Item, Bool) -> [SystemSwipeAction]
    let rowContent: (Item, Bool) -> RowContent

    init(
        items: [Item],
        descriptionText: String,
        reloadIdentifier: AnyHashable? = nil,
        refreshAction: @escaping () async -> Void,
        leadingActions: @escaping (Item, Bool) -> [SystemSwipeAction] = {
            _, _ in []
        },
        trailingActions: @escaping (Item, Bool) -> [SystemSwipeAction],
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.items = items
        self.descriptionText = descriptionText
        self.reloadIdentifier = reloadIdentifier
        self.refreshAction = refreshAction
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.rowContent = rowContent
    }

    var body: some View {
        nativeList
    }

    private var nativeList: some View {
        List {
            Text(descriptionText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(items) { item in
                let isSaved = savedPeople.contains(item.id)

                NativeSwipeInteractionRow {
                    rowContent(item, isSaved)
                }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color(uiColor: .systemBackground))
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        swipeButtons(
                            leadingActions(item, isSaved),
                            item: item,
                            isSaved: isSaved
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        swipeButtons(
                            trailingActions(item, isSaved),
                            item: item,
                            isSaved: isSaved
                        )
                    }
                    .onAppear {
                        savedPeople.refreshProfile(item.savedProfile)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await refreshAction()
        }
    }

    @ViewBuilder
    private func swipeButtons(
        _ actions: [SystemSwipeAction],
        item: Item,
        isSaved: Bool
    ) -> some View {
        ForEach(actions.indices, id: \.self) { index in
            let descriptor = actions[index]
            let presentation = isSaved
                ? descriptor.savedPresentation
                : nil
            let title = presentation?.title ?? descriptor.title
            let systemImage = presentation?.systemImage
                ?? descriptor.systemImage
            let color = presentation?.backgroundColor
                ?? descriptor.backgroundColor

            if descriptor.style == .destructive {
                Button(role: .destructive) {
                    perform(descriptor, for: item)
                } label: {
                    Label(title, systemImage: systemImage)
                }
                .tint(Color(uiColor: color))
            } else {
                Button {
                    perform(descriptor, for: item)
                } label: {
                    Label(title, systemImage: systemImage)
                }
                .tint(Color(uiColor: color))
            }
        }
    }

    private func perform(_ action: SystemSwipeAction, for item: Item) {
        if action.savedPresentation != nil {
            savedPeople.toggle(item.savedProfile)
        }
        action.handler()
    }
}

private final class SystemSwipeTableViewCell: UITableViewCell {
    private struct SwipeOffsets {
        let model: CGFloat
        let presentation: CGFloat

        var visible: CGFloat {
            max(model, presentation)
        }
    }

    private var isInteractionSurfaceEnabled = false
    private var isHeld = false
    private var isSwipePresented = false
    private var isSwipeSurfaceVisible = false
    private var swipeDisplayLink: CADisplayLink?
    private var previousSwipeOffset: CGFloat = 0
    private var maximumSwipeOffset: CGFloat = 0

    private lazy var holdRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleHold(_:))
        )
        recognizer.minimumPressDuration = 0.08
        recognizer.allowableMovement = 12
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        addGestureRecognizer(holdRecognizer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(holdRecognizer)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopMonitoringSwipeMotion()
        isHeld = false
        isSwipePresented = false
        isSwipeSurfaceVisible = false
        contentView.layer.removeAllAnimations()
        updateInteractionSurface(animated: false)
    }

    func configureInteractionSurface(isEnabled: Bool) {
        isInteractionSurfaceEnabled = isEnabled
        holdRecognizer.isEnabled = isEnabled && usesCustomHoldSurface

        if !isEnabled {
            stopMonitoringSwipeMotion()
            isHeld = false
            isSwipePresented = false
            isSwipeSurfaceVisible = false
        }

        updateInteractionSurface(animated: false)
    }

    func setSwipePresented(_ isPresented: Bool) {
        isSwipePresented = isPresented

        if isPresented {
            isSwipeSurfaceVisible = true
            startMonitoringSwipeMotion()
        } else {
            isSwipeSurfaceVisible = false
            stopMonitoringSwipeMotion()
        }

        updateInteractionSurface(animated: true)
    }

    private func startMonitoringSwipeMotion() {
        stopMonitoringSwipeMotion()
        previousSwipeOffset = currentSwipeOffsets.visible
        maximumSwipeOffset = previousSwipeOffset

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(observeSwipeMotion)
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        swipeDisplayLink = displayLink
    }

    private func stopMonitoringSwipeMotion() {
        swipeDisplayLink?.invalidate()
        swipeDisplayLink = nil
    }

    @objc private func observeSwipeMotion() {
        guard isSwipePresented else {
            stopMonitoringSwipeMotion()
            return
        }

        let offsets = currentSwipeOffsets
        let offset = offsets.visible
        maximumSwipeOffset = max(maximumSwipeOffset, offset)

        if !isSwipeSurfaceVisible {
            if isSwipeTouchActive, offset > 4 {
                isSwipeSurfaceVisible = true
                maximumSwipeOffset = offset
                updateInteractionSurface(animated: true)
            }

            previousSwipeOffset = offset
            return
        }

        let isReturningToRest = offsets.model < 1
        let hasStartedReturning = isReturningToRest
            && maximumSwipeOffset > 4
            && offset < previousSwipeOffset - 0.5

        if hasStartedReturning, !isSwipeTouchActive {
            isSwipeSurfaceVisible = false
            updateInteractionSurface(animated: true, duration: 0.5)
        }

        previousSwipeOffset = offset
    }

    private var currentSwipeOffsets: SwipeOffsets {
        guard let window else {
            return SwipeOffsets(model: 0, presentation: 0)
        }

        let restingOriginX = tableView?.convert(.zero, to: window).x
            ?? convert(.zero, to: window).x
        let modelOriginX = contentView.convert(.zero, to: window).x
        let modelOffset = abs(modelOriginX - restingOriginX)

        guard let presentationLayer = contentView.layer.presentation() else {
            return SwipeOffsets(
                model: modelOffset,
                presentation: modelOffset
            )
        }

        let windowLayer = window.layer.presentation() ?? window.layer
        let presentationOffset = abs(
            presentationLayer.convert(.zero, to: windowLayer).x
                - restingOriginX
        )
        return SwipeOffsets(
            model: modelOffset,
            presentation: presentationOffset
        )
    }

    private var tableView: UITableView? {
        sequence(first: superview, next: { $0?.superview })
            .compactMap { $0 as? UITableView }
            .first
    }

    private var isSwipeTouchActive: Bool {
        var currentView: UIView? = self

        while let view = currentView {
            let hasActivePan = view.gestureRecognizers?.contains { recognizer in
                guard recognizer !== holdRecognizer,
                      recognizer is UIPanGestureRecognizer else {
                    return false
                }

                return recognizer.state == .began
                    || recognizer.state == .changed
            } ?? false

            if hasActivePan {
                return true
            }

            currentView = view.superview
        }

        return false
    }

    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
            UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isHeld = true
            updateInteractionSurface(animated: true)
        case .ended, .cancelled, .failed:
            isHeld = false
            updateInteractionSurface(animated: true)
        default:
            break
        }
    }

    private func updateInteractionSurface(
        animated: Bool,
        duration: TimeInterval? = nil
    ) {
        let isVisible = isInteractionSurfaceEnabled
            && (isHeld || isSwipeSurfaceVisible)
        let changes = {
            self.contentView.backgroundColor = isVisible
                ? self.interactionSurfaceColor
                : .clear
            self.contentView.layer.cornerRadius = isVisible
                && self.usesRoundedInteractionSurface ? 26 : 0
            self.contentView.layer.cornerCurve = .continuous
            self.contentView.layer.masksToBounds = isVisible
                && self.usesRoundedInteractionSurface
        }

        guard animated else {
            changes()
            return
        }

        UIView.animate(
            withDuration: duration ?? (isVisible ? 0.16 : 0.5),
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }

    private var interactionSurfaceColor: UIColor {
        guard usesRoundedInteractionSurface else {
            return .systemBackground
        }

        return traitCollection.userInterfaceStyle == .dark
            ? UIColor.tertiarySystemBackground
            : UIColor.systemBackground
    }

    private var usesCustomHoldSurface: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    private var usesRoundedInteractionSurface: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

}

struct SystemSwipeList<Item, RowContent>: UIViewControllerRepresentable
where Item: SavedPeopleListItem & Equatable, RowContent: View {
    let items: [Item]
    let descriptionText: String
    let reloadIdentifier: AnyHashable?
    let refreshAction: () async -> Void
    let leadingActions: (Item, Bool) -> [SystemSwipeAction]
    let trailingActions: (Item, Bool) -> [SystemSwipeAction]
    let rowContent: (Item, Bool) -> RowContent

    init(
        items: [Item],
        descriptionText: String,
        reloadIdentifier: AnyHashable? = nil,
        refreshAction: @escaping () async -> Void,
        leadingActions: @escaping (Item, Bool) -> [SystemSwipeAction] = {
            _, _ in []
        },
        trailingActions: @escaping (Item, Bool) -> [SystemSwipeAction],
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.items = items
        self.descriptionText = descriptionText
        self.reloadIdentifier = reloadIdentifier
        self.refreshAction = refreshAction
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.rowContent = rowContent
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(
        context: Context
    ) -> UITableViewController {
        let controller = UITableViewController(style: .plain)
        let tableView = controller.tableView!

        tableView.backgroundColor = .clear
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.sectionHeaderHeight = 0
        tableView.sectionFooterHeight = 0
        tableView.keyboardDismissMode = .interactive
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.refresh(_:)),
            for: .valueChanged
        )
        tableView.refreshControl = refreshControl

        return controller
    }

    func updateUIViewController(
        _ controller: UITableViewController,
        context: Context
    ) {
        let previous = context.coordinator.parent
        let needsReload = previous.items != items
            || previous.descriptionText != descriptionText
            || previous.reloadIdentifier != reloadIdentifier

        context.coordinator.parent = self

        if needsReload {
            controller.tableView.reloadData()
        }
    }

    final class Coordinator: NSObject,
        UITableViewDataSource,
        UITableViewDelegate {
        var parent: SystemSwipeList
        private let savedPeople = SavedPeopleStateStore.shared

        init(parent: SystemSwipeList) {
            self.parent = parent
        }

        func tableView(
            _ tableView: UITableView,
            numberOfRowsInSection section: Int
        ) -> Int {
            parent.items.count + 1
        }

        func tableView(
            _ tableView: UITableView,
            cellForRowAt indexPath: IndexPath
        ) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "SystemSwipeListCell"
            ) as? SystemSwipeTableViewCell ?? SystemSwipeTableViewCell(
                style: .default,
                reuseIdentifier: "SystemSwipeListCell"
            )

            cell.selectionStyle = .none
            cell.backgroundColor = .clear

            if indexPath.row == 0 {
                cell.configureInteractionSurface(
                    isEnabled: false
                )
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(parent.descriptionText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .margins(.all, 0)
            } else {
                let item = parent.items[indexPath.row - 1]
                savedPeople.refreshProfile(item.savedProfile)
                cell.configureInteractionSurface(
                    isEnabled: true
                )
                cell.contentConfiguration = UIHostingConfiguration {
                    SavedPeopleRow(
                        savedPeople: savedPeople,
                        item: item,
                        rowContent: parent.rowContent
                    )
                }
                .margins(.all, 0)
            }

            return cell
        }

        func tableView(
            _ tableView: UITableView,
            leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
        ) -> UISwipeActionsConfiguration? {
            swipeActionsConfiguration(
                at: indexPath,
                actions: parent.leadingActions,
                allowsFullSwipe: true
            )
        }

        func tableView(
            _ tableView: UITableView,
            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
        ) -> UISwipeActionsConfiguration? {
            swipeActionsConfiguration(
                at: indexPath,
                actions: parent.trailingActions,
                allowsFullSwipe: true
            )
        }

        private func swipeActionsConfiguration(
            at indexPath: IndexPath,
            actions descriptors: (Item, Bool) -> [SystemSwipeAction],
            allowsFullSwipe: Bool
        ) -> UISwipeActionsConfiguration? {
            guard indexPath.row > 0,
                  parent.items.indices.contains(indexPath.row - 1) else {
                return nil
            }

            let item = parent.items[indexPath.row - 1]
            let isSaved = savedPeople.contains(item.id)
            let actions = descriptors(item, isSaved).map { descriptor in
                let presentation = isSaved
                    ? descriptor.savedPresentation
                    : nil
                let action = UIContextualAction(
                    style: descriptor.style,
                    title: presentation?.title ?? descriptor.title
                ) { _, _, completion in
                    if descriptor.savedPresentation != nil {
                        self.savedPeople.toggle(item.savedProfile)
                    }

                    descriptor.handler()
                    completion(true)
                }
                action.image = UIImage(
                    systemName: presentation?.systemImage
                        ?? descriptor.systemImage
                )
                action.backgroundColor = presentation?.backgroundColor
                    ?? descriptor.backgroundColor
                return action
            }

            guard !actions.isEmpty else { return nil }

            let configuration = UISwipeActionsConfiguration(actions: actions)
            configuration.performsFirstActionWithFullSwipe = allowsFullSwipe
            return configuration
        }

        func tableView(
            _ tableView: UITableView,
            willBeginEditingRowAt indexPath: IndexPath
        ) {
            guard indexPath.row > 0,
                  let cell = tableView.cellForRow(at: indexPath)
                    as? SystemSwipeTableViewCell else {
                return
            }

            cell.setSwipePresented(true)
        }

        func tableView(
            _ tableView: UITableView,
            didEndEditingRowAt indexPath: IndexPath?
        ) {
            guard let indexPath,
                  let cell = tableView.cellForRow(at: indexPath)
                    as? SystemSwipeTableViewCell else {
                return
            }

            cell.setSwipePresented(false)
        }

        @objc func refresh(_ refreshControl: UIRefreshControl) {
            Task { @MainActor in
                await parent.refreshAction()
                refreshControl.endRefreshing()
            }
        }
    }
}
