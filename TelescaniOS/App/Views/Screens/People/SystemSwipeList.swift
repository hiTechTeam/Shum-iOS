import SwiftUI
import UIKit

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
                systemImage: "minus",
                backgroundColor: .systemGray
            ),
            handler: { }
        )
    }
}

private final class SavedPeopleStateStore: ObservableObject {
    static let shared = SavedPeopleStateStore()

    private let storageKey = "savedPeopleProfileIDs"
    @Published private var savedIDs: Set<UUID>

    private init() {
        savedIDs = Set(
            UserDefaults.standard
                .stringArray(forKey: storageKey)?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
    }

    func contains(_ id: UUID) -> Bool {
        savedIDs.contains(id)
    }

    @discardableResult
    func toggle(_ id: UUID) -> Bool {
        let isSaved: Bool

        if savedIDs.remove(id) != nil {
            isSaved = false
        } else {
            savedIDs.insert(id)
            isSaved = true
        }

        UserDefaults.standard.set(
            savedIDs.map(\.uuidString).sorted(),
            forKey: storageKey
        )
        return isSaved
    }
}

private struct SavedPeopleRow<Item, RowContent>: View
where Item: Identifiable, Item.ID == UUID, RowContent: View {
    @ObservedObject var savedPeople: SavedPeopleStateStore

    let item: Item
    let rowContent: (Item, Bool) -> RowContent

    var body: some View {
        rowContent(item, savedPeople.contains(item.id))
    }
}

private final class SystemSwipeTableViewCell: UITableViewCell {
    private var isInteractionSurfaceEnabled = false
    private var isHeld = false
    private var isSwipePresented = false

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
        isHeld = false
        isSwipePresented = false
        contentView.layer.removeAllAnimations()
        updateInteractionSurface(animated: false)
    }

    func configureInteractionSurface(isEnabled: Bool) {
        isInteractionSurfaceEnabled = isEnabled
        holdRecognizer.isEnabled = isEnabled

        if !isEnabled {
            isHeld = false
            isSwipePresented = false
        }

        updateInteractionSurface(animated: false)
    }

    func setSwipePresented(_ isPresented: Bool) {
        isSwipePresented = isPresented
        updateInteractionSurface(animated: true)
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
            && (isHeld || isSwipePresented)
        let changes = {
            self.contentView.backgroundColor = isVisible
                ? self.interactionSurfaceColor
                : .clear
            self.contentView.layer.cornerRadius = isVisible ? 26 : 0
            self.contentView.layer.cornerCurve = .continuous
            self.contentView.layer.masksToBounds = isVisible
        }

        guard animated else {
            changes()
            return
        }

        UIView.animate(
            withDuration: duration ?? (isVisible ? 0.16 : 0.24),
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }

    private var interactionSurfaceColor: UIColor {
        traitCollection.userInterfaceStyle == .dark
            ? .tertiarySystemBackground
            : .systemBackground
    }

}

struct SystemSwipeList<Item, RowContent>: UIViewControllerRepresentable
where Item: Identifiable & Equatable, Item.ID == UUID, RowContent: View {
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
                        self.savedPeople.toggle(item.id)
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
