#if os(iOS)
import SwiftUI
import UIKit
import BitFoundation

/// The chat list on UITableView. SwiftUI List on iOS 26 cannot move a row
/// reliably after a swipe action, so the list itself is UIKit and only the
/// row content stays SwiftUI. This shell presents what the list asks for:
/// the profile card, the block sheet and the confirmation alert.
struct ShumChatTableList<Header: View, Empty: View>: View {
    let runtime: ShumRuntime
    let folder: ShumChatFolder
    let entries: [ShumDirectoryEntry]
    let open: (ShumUIRoute) -> Void
    let refresh: () -> Void
    let header: Header
    let empty: Empty
    @State private var selectedPeer: ShumPeer?
    @State private var pendingAction: DirectoryConfirmation?
    @State private var blockRequest: ShumProfileBlockRequest?

    init(
        runtime: ShumRuntime,
        folder: ShumChatFolder,
        entries: [ShumDirectoryEntry],
        open: @escaping (ShumUIRoute) -> Void,
        refresh: @escaping () -> Void,
        @ViewBuilder header: () -> Header,
        @ViewBuilder empty: () -> Empty
    ) {
        self.runtime = runtime
        self.folder = folder
        self.entries = entries
        self.open = open
        self.refresh = refresh
        self.header = header()
        self.empty = empty()
    }

    var body: some View {
        ShumChatTableRepresentable(
            runtime: runtime,
            folder: folder,
            entries: entries,
            open: open,
            refresh: refresh,
            showProfile: { selectedPeer = $0 },
            confirm: { pendingAction = $0 },
            block: { entry, afterSwipe in
                guard let card = entry.card else { return }
                blockRequest = ShumProfileBlockRequest(
                    peer: entry.peer, card: card, waitsForTransientUI: afterSwipe
                )
            },
            header: header,
            empty: empty
        )
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                open(.conversation(peer))
            }
            .presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
        .alert(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("Отмена".localized, role: .cancel) { pendingAction = nil }
            Button(action.buttonTitle, role: .destructive) { confirm(action); pendingAction = nil }
        } message: { action in Text(action.message) }
    }

    private func confirm(_ action: DirectoryConfirmation) {
        switch action {
        case .clear(let card):
            do { try runtime.permanent?.clearDirectoryEntry(card) }
            catch { runtime.error = error.localizedDescription }
        case .decline(let card):
            _ = runtime.declineInvitation(from: card.peerID)
        }
    }
}

private struct ShumChatTableRepresentable<Header: View, Empty: View>: UIViewControllerRepresentable {
    let runtime: ShumRuntime
    let folder: ShumChatFolder
    let entries: [ShumDirectoryEntry]
    let open: (ShumUIRoute) -> Void
    let refresh: () -> Void
    let showProfile: (ShumPeer) -> Void
    let confirm: (DirectoryConfirmation) -> Void
    let block: (ShumDirectoryEntry, Bool) -> Void
    let header: Header
    let empty: Empty

    func makeUIViewController(context: Context) -> ShumChatTableController {
        ShumChatTableController()
    }

    func updateUIViewController(_ controller: ShumChatTableController, context: Context) {
        controller.update(
            ShumChatTableController.State(
                runtime: runtime,
                palette: context.environment.shumThemePalette,
                folder: folder,
                entries: entries,
                open: open,
                refresh: refresh,
                showProfile: showProfile,
                confirm: confirm,
                block: block,
                header: AnyView(header),
                empty: AnyView(empty)
            )
        )
    }
}

/// The line under a row. The table's own separators also draw under the swipe
/// buttons, so the row carries its line in its background instead.
private final class ShumRowSeparatorView: UIView {
    static let leading: CGFloat = 86
    private let line = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        line.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.24 * 0.6)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let height = 1 / scale
        line.frame = CGRect(
            x: Self.leading,
            y: bounds.height - height,
            width: max(0, bounds.width - Self.leading),
            height: height
        )
    }
}

/// Dims the row while it is pressed and keeps the system selection and
/// highlight backgrounds out of the way. The system waits a moment before it
/// highlights, so a swipe or scroll never flashes the row, and a quick tap is
/// highlighted when the finger lifts.
private final class ShumChatCell: UITableViewCell {
    /// The constant surface of a pinned row.
    var pinnedSurface: UIColor? {
        didSet { setNeedsUpdateConfiguration() }
    }
    var showsSeparator = true {
        didSet { setNeedsUpdateConfiguration() }
    }
    private let separatorView = ShumRowSeparatorView()

    private static let swipeSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .tertiarySystemBackground : .secondarySystemBackground
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
    }

    /// A swiped row sits on a rounded surface, a pinned row on a constant one,
    /// like the rows of the people screen.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var background = UIBackgroundConfiguration.clear()
        if let pinnedSurface { background.backgroundColor = pinnedSurface }
        if showsSeparator { background.customView = separatorView }
        if #available(iOS 26.0, *), state.isSwiped {
            background.backgroundColor = pinnedSurface ?? Self.swipeSurface
            background.cornerRadius = 26
        }
        // The dim follows the cell's real highlight state, so a highlight
        // that ended while the row was moving can never leave it faded.
        let dim: CGFloat = state.isHighlighted ? 0.3 : 1
        guard window != nil else {
            backgroundConfiguration = background
            contentView.alpha = dim
            return
        }
        UIView.animate(
            withDuration: state.isSwiped ? 0.16 : 0.3, delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { self.backgroundConfiguration = background }
        if state.isHighlighted {
            contentView.layer.removeAllAnimations()
            contentView.alpha = dim
        } else {
            UIView.animate(
                withDuration: 0.2, delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) { self.contentView.alpha = dim }
        }
    }
}

final class ShumChatTableController: UIViewController, UITableViewDelegate {
    struct State {
        let runtime: ShumRuntime
        let palette: ShumThemePalette
        let folder: ShumChatFolder
        let entries: [ShumDirectoryEntry]
        let open: (ShumUIRoute) -> Void
        let refresh: () -> Void
        let showProfile: (ShumPeer) -> Void
        let confirm: (DirectoryConfirmation) -> Void
        let block: (ShumDirectoryEntry, Bool) -> Void
        let header: AnyView
        let empty: AnyView
    }

    /// What a row shows that does not come from the runtime itself. The row
    /// observes the runtime for the rest, so only a change here needs the
    /// cell to be reconfigured.
    private struct RowState: Equatable {
        let name: String
        let card: ShumContactCard?
        let hasChat: Bool
        let isInvitation: Bool
        let invitationPhase: ShumInvitationPhase?
        let invitationAwaitingResponse: Bool
        let isNearby: Bool
        let unread: Int
        let pinned: Bool
        let isLast: Bool
    }

    private struct ThemeKey: Equatable {
        let colorScheme: ColorScheme
        let accent: UIColor
        let canvas: UIColor
    }

    private var state: State?
    private var entriesByID: [PeerID: ShumDirectoryEntry] = [:]
    private var appliedOrder: [PeerID] = []
    private var appliedRows: [PeerID: RowState] = [:]
    private var appliedTheme: ThemeKey?
    private var lastID: PeerID?
    private var appliedFolder: ShumChatFolder?
    /// A swipe moves the cell under the finger, so the table is left alone
    /// until it is back in place. A pin applies at once.
    private var isSwiping = false
    private var hasDeferredUpdate = false
    private var appliesNextUpdateAtOnce = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let headerSpacer = UIView()
    private let headerHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let emptyHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var headerHeight: NSLayoutConstraint!
    private var dataSource: UITableViewDiffableDataSource<Int, PeerID>!
    private var offsetObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureTable()
        configureEmpty()
        configureHeader()
        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderHeight()
    }

    func update(_ new: State) {
        loadViewIfNeeded()
        state = new
        headerHost.rootView = new.header
        emptyHost.rootView = new.empty
        updateHeaderHeight()
        if isSwiping, !appliesNextUpdateAtOnce, new.folder == appliedFolder {
            hasDeferredUpdate = true
            return
        }
        apply(new)
    }

    // MARK: Setup

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 78
        tableView.sectionHeaderTopPadding = 0
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.alwaysBounceVertical = true
        tableView.keyboardDismissMode = .interactive
        tableView.accessibilityIdentifier = "shum.chatDirectory"
        tableView.delegate = self
        tableView.register(ShumChatCell.self, forCellReuseIdentifier: "row")
        tableView.tableHeaderView = headerSpacer

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(didPull), for: .valueChanged)
        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureEmpty() {
        addChild(emptyHost)
        emptyHost.view.backgroundColor = .clear
        if #available(iOS 16.4, *) { emptyHost.safeAreaRegions = [] }
        tableView.backgroundView = emptyHost.view
        emptyHost.didMove(toParent: self)
    }

    /// The folder bar stays pinned under the navigation bar and only follows
    /// the list when it is pulled down. A spacer header keeps the first row
    /// below it.
    private func configureHeader() {
        addChild(headerHost)
        headerHost.view.translatesAutoresizingMaskIntoConstraints = false
        headerHost.view.backgroundColor = .clear
        if #available(iOS 16.4, *) { headerHost.safeAreaRegions = [] }
        view.addSubview(headerHost.view)
        headerHeight = headerHost.view.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            headerHost.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHeight
        ])
        headerHost.didMove(toParent: self)

        offsetObservation = tableView.observe(\.contentOffset, options: [.new]) { [weak self] table, _ in
            let pull = min(0, table.contentOffset.y + table.adjustedContentInset.top)
            self?.headerHost.view.transform = CGAffineTransform(translationX: 0, y: -pull)
        }
    }

    private func configureDataSource() {
        dataSource = UITableViewDiffableDataSource<Int, PeerID>(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            self?.configure(cell, id: id)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    private func updateHeaderHeight() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let height = ceil(
            headerHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        )
        guard abs(height - headerHeight.constant) > 0.5 else { return }
        headerHeight.constant = height
        headerSpacer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = headerSpacer
    }

    // MARK: Data

    private func apply(_ state: State) {
        appliesNextUpdateAtOnce = false
        hasDeferredUpdate = false

        var seen = Set<PeerID>()
        let ids = state.entries.map(\.id).filter { seen.insert($0).inserted }
        entriesByID = Dictionary(state.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lastID = ids.last
        emptyHost.view.isHidden = !ids.isEmpty

        let theme = ThemeKey(
            colorScheme: state.palette.colorScheme,
            accent: state.palette.accentUIColor,
            canvas: state.palette.canvasUIColor
        )
        var rows: [PeerID: RowState] = [:]
        for id in ids {
            guard let entry = entriesByID[id] else { continue }
            rows[id] = RowState(
                name: entry.peer.name,
                card: entry.card,
                hasChat: entry.hasChat,
                isInvitation: entry.isInvitation,
                invitationPhase: entry.invitationPhase,
                invitationAwaitingResponse: entry.invitationAwaitingResponse,
                isNearby: entry.isNearby,
                unread: entry.unread,
                pinned: isPinned(entry, in: state),
                isLast: id == lastID
            )
        }
        let themeChanged = theme != appliedTheme
        let changed = ids.filter { id in
            guard let old = appliedRows[id] else { return false }
            return themeChanged || old != rows[id]
        }
        let reordered = ids != appliedOrder
        let folderChanged = appliedFolder != state.folder
        guard reordered || folderChanged || !changed.isEmpty else { return }

        var snapshot = NSDiffableDataSourceSnapshot<Int, PeerID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(changed)
        let animate = tableView.window != nil && !folderChanged
        dataSource.apply(snapshot, animatingDifferences: animate)

        appliedOrder = ids
        appliedRows = rows
        appliedTheme = theme
        appliedFolder = state.folder
    }

    private func configure(_ cell: UITableViewCell, id: PeerID) {
        guard let state, let entry = entriesByID[id] else { return }
        let palette = state.palette
        let runtime = state.runtime
        let folder = state.folder
        let pinned = isPinned(entry, in: state)

        if let chatCell = cell as? ShumChatCell {
            chatCell.pinnedSurface = pinned ? UIColor(palette.pinnedRowSurface) : nil
            chatCell.showsSeparator = id != lastID
        }
        cell.contentConfiguration = UIHostingConfiguration {
            ShumDirectoryRow(
                runtime: runtime,
                entry: entry,
                isPinned: pinned,
                showsNearbyIndicator: folder != .nearby
            )
            .environment(\.shumThemePalette, palette)
        }
        .margins(.all, 0)
    }

    private func entry(at indexPath: IndexPath) -> ShumDirectoryEntry? {
        dataSource.itemIdentifier(for: indexPath).flatMap { entriesByID[$0] }
    }

    private func isPinned(_ entry: ShumDirectoryEntry, in state: State) -> Bool {
        guard let card = entry.card else { return false }
        return state.runtime.permanent?.isPinned(card, in: state.folder.pinKey) == true
    }

    private func canClear(_ entry: ShumDirectoryEntry, in state: State) -> Bool {
        entry.hasChat && !state.runtime.conversation(entry.peer.id).isEmpty
    }

    private func togglePinned(_ entry: ShumDirectoryEntry) {
        guard let state, let card = entry.card else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        appliesNextUpdateAtOnce = true
        do {
            _ = try state.runtime.permanent?.togglePinned(card, in: state.folder.pinKey)
        } catch {
            state.runtime.error = error.localizedDescription
        }
    }

    // MARK: Actions

    @objc private func didPull() {
        state?.refresh()
        DispatchQueue.main.async { [weak self] in
            self?.tableView.refreshControl?.endRefreshing()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let entry = entry(at: indexPath) else { return }
        state?.open(.conversation(entry.peer))
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        isSwiping = true
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        isSwiping = false
        if hasDeferredUpdate, let state { apply(state) }
    }

    // MARK: Swipe actions

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let state, let entry = entry(at: indexPath), entry.card != nil else { return nil }
        let pinned = isPinned(entry, in: state)
        let pin = UIContextualAction(
            style: .normal,
            title: pinned ? "Открепить".localized : "Закрепить".localized
        ) { [weak self] _, _, completion in
            self?.togglePinned(entry)
            completion(true)
        }
        pin.image = UIImage(systemName: pinned ? "pin.slash" : "pin.fill")
        pin.backgroundColor = .systemGray
        let configuration = UISwipeActionsConfiguration(actions: [pin])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let state, let entry = entry(at: indexPath), let card = entry.card else { return nil }

        func action(
            _ title: String, _ symbol: String, _ color: UIColor, _ perform: @escaping () -> Void
        ) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: title) { _, _, completion in
                perform()
                completion(true)
            }
            action.image = UIImage(systemName: symbol)
            action.backgroundColor = color
            return action
        }
        let block = action("Заблокировать".localized, "person.crop.circle.badge.xmark", .systemRed) {
            state.block(entry, true)
        }
        var actions: [UIContextualAction]
        if entry.isInvitation && entry.invitationPhase == .incomingPending {
            let decline = action("Отклонить".localized, "xmark", .systemRed) {
                state.confirm(.decline(card))
            }
            actions = [decline, block]
        } else {
            actions = [block]
            if canClear(entry, in: state) {
                actions.append(action("Очистить".localized, "trash", .systemGray) {
                    state.confirm(.clear(card))
                })
            }
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    // MARK: Context menu

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let state, let entry = entry(at: indexPath) else { return nil }
        let pinned = isPinned(entry, in: state)
        return UIContextMenuConfiguration(
            identifier: indexPath as NSIndexPath,
            previewProvider: {
                let preview = UIHostingController(
                    rootView: ShumDirectoryContextPreview(
                        runtime: state.runtime,
                        entry: entry,
                        isPinned: pinned,
                        showsNearbyIndicator: state.folder != .nearby
                    )
                    .environment(\.shumThemePalette, state.palette)
                )
                let size = preview.sizeThatFits(
                    in: CGSize(width: UIScreen.main.bounds.width, height: .greatestFiniteMagnitude)
                )
                preview.preferredContentSize = size
                // The row has no surface of its own; the lifted card gets the
                // screen's canvas in the same capsule the row is clipped to.
                preview.view.backgroundColor = UIColor(state.palette.canvas)
                preview.view.layer.cornerCurve = .continuous
                preview.view.layer.cornerRadius = size.height / 2
                preview.view.clipsToBounds = true
                return preview
            },
            actionProvider: { [weak self] _ in
                self?.menu(for: entry, pinned: pinned, state: state)
            }
        )
    }

    private func menu(for entry: ShumDirectoryEntry, pinned: Bool, state: State) -> UIMenu {
        var elements: [UIMenuElement] = []
        if let card = entry.card, !state.runtime.isContact(entry.peer.id) {
            elements.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: "Добавить в контакты".localized,
                    image: UIImage(systemName: "person.badge.plus")
                ) { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    _ = state.runtime.addContact(card, source: "chat-menu")
                }
            ]))
        }
        elements.append(UIAction(
            title: "Посмотреть профиль".localized,
            image: UIImage(systemName: "person.crop.circle")
        ) { _ in state.showProfile(entry.peer) })
        elements.append(UIAction(
            title: entry.isInvitation ? "Открыть приглашение".localized : "Написать".localized,
            image: UIImage(systemName: "paperplane")
        ) { _ in state.open(.conversation(entry.peer)) })
        if let card = entry.card {
            elements.append(UIAction(
                title: pinned ? "Открепить".localized : "Закрепить".localized,
                image: UIImage(systemName: pinned ? "pin.slash" : "pin.fill")
            ) { [weak self] _ in self?.togglePinned(entry) })
            if entry.isInvitation, entry.invitationPhase == .incomingPending {
                elements.append(UIAction(
                    title: "Отклонить приглашение".localized,
                    image: UIImage(systemName: "xmark"),
                    attributes: .destructive
                ) { _ in state.confirm(.decline(card)) })
            } else if canClear(entry, in: state) {
                elements.append(UIAction(
                    title: "Очистить".localized,
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in state.confirm(.clear(card)) })
            }
            elements.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: "Заблокировать".localized,
                    image: UIImage(systemName: "person.crop.circle.badge.xmark"),
                    attributes: .destructive
                ) { _ in state.block(entry, false) }
            ]))
        }
        return UIMenu(children: elements)
    }
}
#endif
