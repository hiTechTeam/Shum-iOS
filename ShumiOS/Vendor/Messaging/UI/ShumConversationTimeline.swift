#if os(iOS)
import SwiftUI
import UIKit

struct ShumTimelineItem: Equatable {
    let id: String
    let revision: Int
}

struct ShumTimelineCommand: Equatable {
    enum Target: Equatable { case bottom, message(String) }
    let id = UUID()
    let target: Target
}

extension Notification.Name {
    static let shumHighlightMessage = Notification.Name("shum.highlight-message")
}

/// A message and its visible offset survive changes to the history above it.
/// No message contents are stored in preferences.
struct ShumTimelinePosition: Codable {
    let messageID: String
    let offset: CGFloat
    let atBottom: Bool
    let lastMessageID: String?

    static func load(key: String) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// UIKit owns scrolling and navigation geometry. The existing SwiftUI bubbles,
/// including their long-press and reply gestures, are hosted unchanged in rows.
struct ShumConversationTimeline<Row: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let items: [ShumTimelineItem]
    let storageKey: String
    let appearanceKey: String
    let command: ShumTimelineCommand?
    var contentInsets: EdgeInsets = EdgeInsets()
    let bottomChanged: (Bool) -> Void
    let tapped: () -> Void
    @ViewBuilder let row: (Int, CGFloat) -> Row

    func makeUIViewController(context: Context) -> ShumTimelineController {
        ShumTimelineController(storageKey: storageKey)
    }

    func updateUIViewController(_ controller: ShumTimelineController, context: Context) {
        controller.bottomChanged = bottomChanged
        controller.tapped = tapped
        controller.viewportInsets = UIEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom + 10, right: 0)
        controller.update(items: items, appearanceKey: "\(appearanceKey)-\(environment.dynamicTypeSize)-\(environment.locale.identifier)", command: command) { index, width in
            AnyView(row(index, width).environment(\.self, environment))
        }
    }
}

final class ShumTimelineController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let measurementHost = UIHostingController(rootView: AnyView(EmptyView()))
    private let storageKey: String
    private var items: [ShumTimelineItem] = []
    private var row: (Int, CGFloat) -> AnyView = { _, _ in AnyView(EmptyView()) }
    private var appearanceKey = ""
    private var heights: [String: CGFloat] = [:]
    private var restored = false
    private var leaving = false
    private var adjusting = false
    private var followsBottom = true
    private var reportedBottom: Bool?
    private var lastCommand: UUID?
    private var pendingCommand: ShumTimelineCommand?
    private var highlightWork: DispatchWorkItem?
    private var scrollingToBottom = false
    private var saveWork: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    var viewportInsets = UIEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
    var bottomChanged: (Bool) -> Void = { _ in }
    var tapped: () -> Void = {}

    init(storageKey: String) {
        self.storageKey = storageKey
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.contentInsetAdjustmentBehavior = .never
        table.automaticallyAdjustsScrollIndicatorInsets = false
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 0
        table.selfSizingInvalidation = .disabled
        if #available(iOS 16.4, *) { measurementHost.safeAreaRegions = [] }
        table.sectionHeaderTopPadding = 0
        table.keyboardDismissMode = .interactive
        table.delaysContentTouches = false
        table.dataSource = self
        table.delegate = self
        table.register(ShumTimelineCell.self, forCellReuseIdentifier: "message")
        table.accessibilityIdentifier = "shum.timeline"
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        table.addGestureRecognizer(tap)
        view.addSubview(table)
        setContentScrollView(table, for: .all)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.persistPosition() }
    }

    deinit {
        saveWork?.cancel()
        highlightWork?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        leaving = false
        // SwiftUI owns the navigation controller; explicitly give its bar the
        // real scroll view so native background blur tracks the history too.
        navigationController?.topViewController?.setContentScrollView(table, for: .top)
        view.setNeedsLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        // Capture before the navigation bar/tab bar/keyboard change the safe area.
        persistPosition()
        leaving = true
        table.setContentOffset(table.contentOffset, animated: false)
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !leaving, view.bounds.width > 0, view.bounds.height > 0, !adjusting else { return }
        adjusting = true
        defer { adjusting = false }
        UIView.performWithoutAnimation {
            let position = restored ? currentPosition() : ShumTimelinePosition.load(key: storageKey)
            let effectiveInsets = resolvedViewportInsets()
            let changedSize = table.frame.size != view.bounds.size
            let changedInsets = table.contentInset != effectiveInsets
            let changedWidth = table.frame.width != view.bounds.width
            if changedWidth { heights.removeAll() }
            table.frame = view.bounds
            table.contentInset = effectiveInsets
            table.verticalScrollIndicatorInsets = effectiveInsets
            if changedWidth { table.reloadData() }
            table.layoutIfNeeded()
            if !restored, !items.isEmpty {
                restore(position)
                restored = true
            } else if changedSize || changedInsets, restored {
                // A keyboard or composer resize keeps the same reading position.
                restore(position)
            }
            performPendingCommand()
        }
        reportBottom()
    }

    /// SwiftUI already shortens this controller when the keyboard is visible.
    /// Its reported safe-area bottom still contains the keyboard height, so
    /// applying that value unchanged would create a second, scrollable keyboard
    /// sized gap below the final message. Keep only the part that actually
    /// overlaps this controller (composer and any remaining system safe area).
    private func resolvedViewportInsets() -> UIEdgeInsets {
        var insets = viewportInsets
        guard let window = view.window else { return insets }
        let frame = view.convert(view.bounds, to: window)
        let areaAlreadyOutsideViewport = max(0, window.bounds.maxY - frame.maxY)
        insets.bottom = max(0, insets.bottom - areaAlreadyOutsideViewport)
        return insets
    }

    func update(items newItems: [ShumTimelineItem], appearanceKey: String,
                command: ShumTimelineCommand?, row: @escaping (Int, CGFloat) -> AnyView) {
        loadViewIfNeeded()
        self.row = row
        if let command, command.id != lastCommand { pendingCommand = command }
        let oldItems = items
        let themeChanged = self.appearanceKey != appearanceKey
        self.appearanceKey = appearanceKey
        guard newItems != oldItems || themeChanged else {
            performPendingCommand()
            return
        }
        let position = restored ? currentPosition() : nil
        let appended = newItems.count > oldItems.count && Array(newItems.prefix(oldItems.count)).map(\.id) == oldItems.map(\.id)
        let changedRows = newItems.indices.filter { index in
            themeChanged || index >= oldItems.count || newItems[index] != oldItems[index]
        }
        for index in changedRows { heights.removeValue(forKey: newItems[index].id) }
        items = newItems
        adjusting = true
        UIView.performWithoutAnimation {
            if appended, restored {
                table.insertRows(at: (oldItems.count..<items.count).map { IndexPath(row: $0, section: 0) }, with: .none)
            } else if newItems.map(\.id) != oldItems.map(\.id) || !restored {
                table.reloadData()
            }
            // Reconfigure only changed visible rows; typing/presence refreshes do
            // not replace message views or disturb a held bubble.
            for index in changedRows {
                if let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) {
                    configure(cell, index: index)
                }
            }
            if restored, !appended, newItems.map(\.id) == oldItems.map(\.id) {
                table.beginUpdates()
                table.endUpdates()
            }
            table.layoutIfNeeded()
            if restored, !leaving { restore(position, followNewMessages: appended) }
            if items.isEmpty { UserDefaults.standard.removeObject(forKey: storageKey) }
        }
        adjusting = false
        view.setNeedsLayout()
        if !leaving { performPendingCommand(); reportBottom() }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath)
        configure(cell, index: indexPath.row)
        return cell
    }

    private func configure(_ cell: UITableViewCell, index: Int) {
        cell.accessibilityIdentifier = "shum.row.\(items[index].id)"
        cell.backgroundColor = .clear
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        cell.contentView.clipsToBounds = false
        cell.clipsToBounds = false
        guard let cell = cell as? ShumTimelineCell else { return }
        cell.setContent(
            AnyView(row(index, table.bounds.width).id(items[index].id)),
            parent: self
        )
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let id = items[indexPath.row].id
        if let height = heights[id] { return height }
        // Resolve a row's height synchronously. An asynchronous self-sizing pass
        // must not move the viewport after a push or after extracting a bubble.
        measurementHost.rootView = row(indexPath.row, tableView.bounds.width)
        let size = measurementHost.sizeThatFits(in: CGSize(width: max(1, tableView.bounds.width),
                                                         height: .greatestFiniteMagnitude))
        let height = max(1, ceil(size.height))
        heights[id] = height
        return height
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard restored, !adjusting, !leaving else { return }
        followsBottom = distanceFromBottom < 4
        reportBottom()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistPosition() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { persistPosition() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { persistPosition() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollingToBottom {
            scrollingToBottom = false
            adjusting = true
            moveToBottom(animated: false)
            adjusting = false
            reportBottom()
        }
        persistPosition()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollingToBottom = false }

    private var distanceFromBottom: CGFloat {
        max(0, table.contentSize.height + table.contentInset.bottom - table.bounds.height - table.contentOffset.y)
    }

    private func currentPosition() -> ShumTimelinePosition? {
        guard restored, !items.isEmpty,
              let path = table.indexPathsForVisibleRows?.sorted().first(where: {
                  table.rectForRow(at: $0).maxY > table.contentOffset.y + table.contentInset.top
              }),
              path.row < items.count else { return nil }
        return ShumTimelinePosition(messageID: items[path.row].id,
            offset: table.rectForRow(at: path).minY - table.contentOffset.y - table.contentInset.top,
            atBottom: followsBottom, lastMessageID: items.last?.id)
    }

    private func restore(_ position: ShumTimelinePosition?, followNewMessages: Bool = false) {
        guard !items.isEmpty else { return }
        let keepAnchor = position.map {
            !$0.atBottom || (!followNewMessages && $0.lastMessageID != items.last?.id)
        } ?? false
        if let position, keepAnchor,
           let index = items.firstIndex(where: { $0.id == position.messageID }) {
            let path = IndexPath(row: index, section: 0)
            if table.cellForRow(at: path) == nil {
                table.scrollToRow(at: path, at: .top, animated: false)
                table.layoutIfNeeded()
            }
            let offset = table.rectForRow(at: path).minY - position.offset - table.contentInset.top
            setOffset(offset, animated: false)
            followsBottom = false
        } else {
            moveToBottom(animated: false)
        }
    }

    private func setOffset(_ value: CGFloat, animated: Bool) {
        let minimum = -table.contentInset.top
        let maximum = max(minimum, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
        table.setContentOffset(CGPoint(x: 0, y: min(max(minimum, value), maximum)), animated: animated)
    }

    private func moveToBottom(animated: Bool) {
        guard !items.isEmpty else { return }
        // Materialize the final rows before computing an exact bottom offset.
        if !animated {
            table.scrollToRow(at: IndexPath(row: items.count - 1, section: 0), at: .bottom, animated: false)
            table.layoutIfNeeded()
        }
        followsBottom = true
        setOffset(table.contentSize.height + table.contentInset.bottom - table.bounds.height, animated: animated)
    }

    private func performPendingCommand() {
        guard restored, !leaving, let command = pendingCommand else { return }
        pendingCommand = nil
        lastCommand = command.id
        switch command.target {
        case .bottom:
            scrollingToBottom = !UIAccessibility.isReduceMotionEnabled
            moveToBottom(animated: scrollingToBottom)
        case .message(let id):
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            followsBottom = false
            table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle,
                              animated: !UIAccessibility.isReduceMotionEnabled)
            scheduleHighlight(for: id)
        }
    }

    private func scheduleHighlight(for messageID: String) {
        highlightWork?.cancel()
        let delay: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0 : 0.32
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.items.contains(where: { $0.id == messageID }) else { return }
            self.table.layoutIfNeeded()
            NotificationCenter.default.post(name: .shumHighlightMessage, object: messageID)
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reportBottom() {
        guard restored else { return }
        let nearBottom = distanceFromBottom < 80
        guard reportedBottom != nearBottom else { return }
        reportedBottom = nearBottom
        DispatchQueue.main.async { [weak self] in self?.bottomChanged(nearBottom) }
    }

    private func persistPosition() {
        saveWork?.cancel()
        guard !leaving, let position = currentPosition() else { return }
        position.save(key: storageKey)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The timeline draws under the composer and navigation bar, but those
        // areas must never dismiss the keyboard through a gap in a control.
        view.bounds.inset(by: resolvedViewportInsets()).contains(touch.location(in: view))
    }

    @objc private func didTap() { tapped() }
}
/// Rows must keep their measured geometry while crossing underneath the bars.
/// UIHostingConfiguration inherits a changing safe area for partially visible
/// cells; a hosting controller with no safe-area regions keeps each bubble in
/// its own row instead of repositioning it over its neighbours.
private final class ShumTimelineCell: UITableViewCell {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        contentView.addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ content: AnyView, parent: UIViewController) {
        if host.parent !== parent {
            host.willMove(toParent: nil)
            host.removeFromParent()
            parent.addChild(host)
            host.didMove(toParent: parent)
        }
        host.rootView = content
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.view.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        host.rootView = AnyView(EmptyView())
        host.willMove(toParent: nil)
        host.removeFromParent()
    }
}
#endif
