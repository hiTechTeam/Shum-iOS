#if os(iOS)
import UIKit

/// Presents the original hosting view above a separate blur, with the pixel
/// reactions above it and the actions below. The bubble has no snapshot,
/// extra fill, shadow, mask or scale greater than one.
final class ShumExtractedMessageMenu: UIView {
    private weak var source: UIView?
    private let bubble: UIView
    private let restore: () -> Void
    private let outgoing: Bool
    private let backdrop = UIVisualEffectView()
    private let scroll = UIScrollView()
    private let menu = ShumExtractedMessageMenu.surface()
    private let reactionBar = ShumExtractedMessageMenu.surface()
    private var actions: [UIButton] = []
    /// Every reaction, the latest first, in a row that scrolls sideways.
    private var reactionButtons: [UIButton] = []
    private let recentRow = UIScrollView()
    /// Every reaction by its part, shown once the chevron opens the bar.
    private var poolSections: [(title: UILabel, buttons: [UIButton])] = []
    private let pool = UIScrollView()
    private var chevron: UIButton?
    private var expanded = false
    private var safeTop: CGFloat = 0
    private var rowHeight: CGFloat = 48
    /// Where to delete the message, offered in place of the actions.
    private let deleteChoices: [ShumMenuChoice]
    private var isDismissing = false
    private var restored = false
    private var initialSize = CGSize.zero
    private var targetBubbleFrame = CGRect.zero
    private var dismissalTouch: MessageDismissalTouch?
    /// Runs once the bubble is back in its row, so a row that grows for a new
    /// reaction does not move under a bubble still travelling back.
    private var afterRestore: (() -> Void)?

    private static let reactionSize: CGFloat = 36
    private static let reactionSpacing: CGFloat = 2
    private static let reactionInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    /// The system glass on iOS 26, the system material before it.
    private static func surface() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    }

    init(source: UIView, bubble: UIView, outgoing: Bool,
         reply: @escaping () -> Void, copy: @escaping () -> Void,
         cancelSending: (() -> Void)?, cancelTitle: String = "Отменить отправку".localized,
         deleteChoices: [ShumMenuChoice] = [],
         reaction: ShumReaction?, react: ((ShumReaction) -> Void)?,
         restore: @escaping () -> Void) {
        self.deleteChoices = deleteChoices
        self.source = source
        self.bubble = bubble
        self.outgoing = outgoing
        self.restore = restore
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overrideUserInterfaceStyle = source.traitCollection.userInterfaceStyle
        backgroundColor = .clear
        accessibilityViewIsModal = true
        addSubview(backdrop)
        addSubview(scroll)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        dismissTap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(dismissTap)

        let radius: CGFloat
        if #available(iOS 26.0, *) { radius = 24 } else { radius = 14 }
        menu.layer.cornerRadius = radius
        menu.layer.cornerCurve = .continuous
        menu.clipsToBounds = true
        menu.alpha = 0
        scroll.addSubview(menu)
        actions = [makeAction("Ответить".localized, symbol: "arrowshape.turn.up.left", action: reply),
                   makeAction("Скопировать".localized, symbol: "doc.on.doc", action: copy)]
        if let cancelSending {
            if deleteChoices.isEmpty {
                actions.append(makeAction(cancelTitle, symbol: "trash", color: .systemRed, action: cancelSending))
            } else {
                actions.append(makeAction(cancelTitle, symbol: "trash", color: .systemRed, dismisses: false) { [weak self] in
                    self?.showDeleteChoices()
                })
            }
        }
        actions.forEach { menu.contentView.addSubview($0) }
        for index in 1..<actions.count {
            let separator = UIView()
            separator.backgroundColor = .separator
            separator.tag = index
            menu.contentView.addSubview(separator)
        }

        if let react {
            reactionBar.layer.cornerCurve = .continuous
            reactionBar.clipsToBounds = true
            reactionBar.alpha = 0
            scroll.addSubview(reactionBar)
            // Every reaction, the latest first, in a row that scrolls
            // sideways, and a chevron that opens them all by their parts.
            reactionButtons = ShumRecentReactions.order.map { option in
                makeReaction(option, selected: option == reaction) { react(option) }
            }
            recentRow.showsHorizontalScrollIndicator = false
            recentRow.alwaysBounceHorizontal = true
            reactionButtons.forEach { recentRow.addSubview($0) }
            reactionBar.contentView.addSubview(recentRow)
            let chevron = makeChevron()
            self.chevron = chevron
            reactionBar.contentView.addSubview(chevron)
            pool.showsVerticalScrollIndicator = false
            pool.alpha = 0
            pool.isHidden = true
            reactionBar.contentView.addSubview(pool)
            poolSections = ShumReactionArt.sections.map { section in
                let title = UILabel()
                title.text = section.title.uppercased()
                title.font = .systemFont(ofSize: 12, weight: .semibold)
                title.textColor = .secondaryLabel
                title.textAlignment = .center
                pool.addSubview(title)
                let buttons = section.reactions.map { option in
                    makeReaction(option, selected: option == reaction) { react(option) }
                }
                buttons.forEach { pool.addSubview($0) }
                return (title, buttons)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func observeNextTouch() {
        guard #available(iOS 26.0, *), dismissalTouch == nil, let window else { return }
        let recognizer = MessageDismissalTouch { [weak self] in self?.dismiss(animated: false) }
        dismissalTouch = recognizer
        window.addGestureRecognizer(recognizer)
    }

    /// Let the next real touch finish an outgoing presentation immediately.
    /// This does not synthesize or replay touches to the chat underneath.
    static func finishDismissal(in window: UIWindow) {
        for case let menu as ShumExtractedMessageMenu in window.rootViewController?.view.subviews ?? [] where menu.isDismissing {
            menu.dismiss(animated: false)
        }
    }

    private func makeAction(_ title: String, symbol: String, color: UIColor = .label, dismisses: Bool = true,
                            action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        // The system menu's sizes, fixed: the icon at the trailing edge.
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        configuration.imagePlacement = .trailing
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        configuration.baseForegroundColor = color
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .systemFont(ofSize: 16)
            return result
        }
        // The button's own rounded highlight would sit inside the row; the
        // row is filled edge to edge instead, cut by the menu's corners.
        configuration.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
        button.configuration = configuration
        button.contentHorizontalAlignment = .fill
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = color
            button.backgroundColor = button.isHighlighted ? .tertiarySystemFill : .clear
        }
        button.addAction(UIAction { [weak self] _ in
            if dismisses { self?.dismiss(animated: true) }
            action()
        }, for: .touchUpInside)
        return button
    }

    /// As in Telegram: the actions give way to where to delete the message,
    /// in red, in the same place.
    private func showDeleteChoices() {
        UISelectionFeedbackGenerator().selectionChanged()
        let old = menu.contentView.subviews
        let width = menu.bounds.width
        var y: CGFloat = 0
        var added: [UIView] = []
        for (index, choice) in deleteChoices.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.frame = CGRect(x: 0, y: y, width: width, height: 1 / (window?.screen.scale ?? 3))
                added.append(separator)
            }
            var configuration = UIButton.Configuration.plain()
            configuration.title = choice.title
            configuration.baseForegroundColor = .systemRed
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .systemFont(ofSize: 16)
                return result
            }
            configuration.background.backgroundColorTransformer = UIConfigurationColorTransformer { _ in .clear }
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            button.configurationUpdateHandler = { button in
                button.backgroundColor = button.isHighlighted ? .tertiarySystemFill : .clear
            }
            button.addAction(UIAction { [weak self] _ in
                self?.dismiss(animated: true)
                choice.action()
            }, for: .touchUpInside)
            let height = max(rowHeight, button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            button.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
            added.append(button)
        }
        added.forEach { $0.alpha = 0; menu.contentView.addSubview($0) }
        actions = added.compactMap { $0 as? UIButton }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, delay: 0,
                       usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            old.forEach { $0.alpha = 0 }
            added.forEach { $0.alpha = 1 }
            self.menu.frame.size.height = y
        } completion: { _ in
            old.forEach { $0.removeFromSuperview() }
            UIAccessibility.post(notification: .layoutChanged, argument: added.first { $0 is UIButton })
        }
    }

    /// The current reaction is highlighted; choosing it again takes it back.
    private func makeReaction(_ reaction: ShumReaction, selected: Bool,
                              action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = ShumReactionArt.image(for: reaction, size: 26)
        configuration.contentInsets = .zero
        configuration.background.cornerRadius = Self.reactionSize / 2
        let selection = ShumAppearanceStore.shared.accentUIColor.withAlphaComponent(0.3)
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted
                ? .tertiarySystemFill : (selected ? selection : .clear)
        }
        button.accessibilityLabel = ShumReactionArt.name(for: reaction)
        if selected {
            button.accessibilityTraits.insert(.selected)
            button.accessibilityHint = "Нажмите ещё раз, чтобы убрать реакцию".localized
        }
        button.addAction(UIAction { [weak self] _ in
            UISelectionFeedbackGenerator().selectionChanged()
            ShumRecentReactions.used(reaction)
            self?.afterRestore = action
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        return button
    }

    private func makeChevron() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        configuration.baseForegroundColor = .label
        // See-through over the reactions scrolling under it.
        configuration.background.backgroundColor = .clear
        configuration.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        configuration.background.cornerRadius = Self.reactionSize / 2
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Все реакции".localized
        button.addAction(UIAction { [weak self] _ in self?.toggleReactions() }, for: .touchUpInside)
        return button
    }

    /// The bar grows upwards into every reaction, eight to a row; the
    /// actions step aside meanwhile.
    private func toggleReactions() {
        expanded.toggle()
        UISelectionFeedbackGenerator().selectionChanged()
        pool.isHidden = false
        scroll.bringSubviewToFront(reactionBar)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.32, delay: 0,
                       usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutReactionBar()
            self.placeBubbleUnderBar()
            self.chevron?.transform = self.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
            self.menu.alpha = self.expanded ? 0 : 1
            self.pool.alpha = self.expanded ? 1 : 0
        } completion: { _ in
            if !self.expanded { self.pool.isHidden = true }
        }
    }

    /// Reactions to a row: seven of the latest and the chevron, or eight
    /// in the opened set.
    private static let perRow = 8

    /// Lays the bar out over the bubble: the row of the latest, or with
    /// every reaction under it once open, kept on screen.
    private func layoutReactionBar() {
        guard !reactionButtons.isEmpty else { return }
        let inset = Self.reactionInset
        let size = Self.reactionSize
        let step = size + Self.reactionSpacing
        let rowWidth = CGFloat(Self.perRow) * step - Self.reactionSpacing
        // The row runs under the whole capsule, edge to edge, and under the
        // see-through chevron; its ends can still scroll into the open.
        let barWidth = rowWidth + inset.left + inset.right
        let firstLayout = recentRow.frame.width == 0
        recentRow.frame = CGRect(x: 0, y: inset.top, width: barWidth, height: size)
        recentRow.contentInset = UIEdgeInsets(top: 0, left: inset.left, bottom: 0, right: inset.right + step)
        recentRow.contentSize = CGSize(width: CGFloat(reactionButtons.count) * step - Self.reactionSpacing, height: size)
        if firstLayout { recentRow.contentOffset = CGPoint(x: -inset.left, y: 0) }
        for (index, button) in reactionButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * step, y: 0, width: size, height: size)
        }
        chevron?.frame = CGRect(x: barWidth - inset.right - size, y: inset.top, width: size, height: size)
        var y: CGFloat = 0
        for (index, section) in poolSections.enumerated() {
            // The emoji come first without a title, as in the design.
            section.title.isHidden = index == 0
            if index > 0 {
                section.title.frame = CGRect(x: 0, y: y + 6, width: rowWidth, height: 16)
                y += 28
            }
            for (place, button) in section.buttons.enumerated() {
                button.frame = CGRect(x: CGFloat(place % Self.perRow) * step,
                                      y: y + CGFloat(place / Self.perRow) * step, width: size, height: size)
            }
            y += CGFloat((section.buttons.count + Self.perRow - 1) / Self.perRow) * step
        }
        pool.contentSize = CGSize(width: rowWidth, height: y)
        let bottom = targetBubbleFrame.minY - 10
        let rowRoom = size + inset.top + inset.bottom + 10
        let poolHeight = expanded ? min(y, max(300, bottom - safeTop - rowRoom)) : 0
        pool.frame = CGRect(x: inset.left, y: inset.top + size + 10, width: rowWidth, height: poolHeight)
        let width = rowWidth + inset.left + inset.right
        let height = size + inset.top + inset.bottom + (expanded ? poolHeight + 10 : 0)
        let x = max(16, min(outgoing ? targetBubbleFrame.maxX - width : targetBubbleFrame.minX, bounds.width - width - 16))
        reactionBar.frame = CGRect(x: x, y: max(safeTop, bottom - height), width: width, height: height)
        reactionBar.layer.cornerRadius = expanded ? 22 : height / 2
    }

    /// Opened over a bubble near the top, the set pushes the bubble down
    /// under it, as in the design; closed, the bubble goes back.
    private func placeBubbleUnderBar() {
        let push = expanded ? max(0, reactionBar.frame.maxY + 10 - targetBubbleFrame.minY) : 0
        bubble.center = CGPoint(x: targetBubbleFrame.midX, y: targetBubbleFrame.midY + push)
        // A tall bubble pushed past the bottom can still be scrolled to.
        scroll.contentSize.height = max(scroll.contentSize.height, targetBubbleFrame.maxY + push + 20)
    }

    func present(in window: UIWindow) {
        Self.finishDismissal(in: window)
        guard let source, let surface = window.rootViewController?.view else { restoreOnce(); return }
        frame = surface.convert(window.bounds, from: window)
        initialSize = bounds.size
        backdrop.frame = bounds
        scroll.frame = bounds
        let sourceFrame = source.convert(source.bounds, to: window)
        rowHeight = 44
        let menuSize = CGSize(width: min(250, bounds.width - 32), height: rowHeight * CGFloat(actions.count))
        let inset = Self.reactionInset
        let count = CGFloat(reactionButtons.count)
        let barSize = CGSize(width: count * Self.reactionSize + max(0, count - 1) * Self.reactionSpacing + inset.left + inset.right,
                             height: Self.reactionSize + inset.top + inset.bottom)
        let barRoom = reactionButtons.isEmpty ? 0 : barSize.height + 10
        let top = window.safeAreaInsets.top + 12
        var bottom = bounds.height - window.safeAreaInsets.bottom - 12
        if let root = window.rootViewController?.view {
            let keyboard = root.convert(root.keyboardLayoutGuide.layoutFrame, to: window)
            if keyboard.height > window.safeAreaInsets.bottom + 20 { bottom = min(bottom, keyboard.minY - 12) }
        }

        // Keep the original position whenever there is room. Exceptionally long
        // messages remain full-size and can scroll together with their actions.
        var bubbleFrame = sourceFrame
        let menuRoom = menuSize.height + 40
        bubbleFrame.origin.y = max(top + barRoom, min(sourceFrame.minY, bottom - menuRoom - bubbleFrame.height))
        func aligned(_ width: CGFloat) -> CGFloat {
            max(16, min(outgoing ? bubbleFrame.maxX - width : bubbleFrame.minX, bounds.width - width - 16))
        }
        menu.frame = CGRect(origin: CGPoint(x: aligned(menuSize.width), y: bubbleFrame.maxY + 8), size: menuSize)
        for (index, button) in actions.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: menuSize.width, height: rowHeight)
        }
        for index in 1..<max(actions.count, 1) {
            menu.contentView.viewWithTag(index)?.frame = CGRect(x: 0, y: rowHeight * CGFloat(index),
                                                                width: menuSize.width, height: 1 / window.screen.scale)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, menu.frame.maxY + window.safeAreaInsets.bottom + 12))
        targetBubbleFrame = bubbleFrame
        safeTop = top
        layoutReactionBar()

        surface.addSubview(self)
        source.accessibilityElementsHidden = true
        // Moving the existing view also preserves its SwiftUI environment,
        // including palette and text measurements.
        scroll.addSubview(bubble)
        bubble.bounds = CGRect(origin: .zero, size: sourceFrame.size)
        bubble.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        bubble.isUserInteractionEnabled = false
        reactionBar.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        layoutIfNeeded()
        animatePresentation()
    }

    private func animatePresentation() {
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reducedMotion ? 0 : 0.28, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.bubble.transform = .identity
            self.bubble.center = CGPoint(x: self.targetBubbleFrame.midX, y: self.targetBubbleFrame.midY)
            self.reactionBar.transform = .identity
        }
        UIView.animate(withDuration: reducedMotion ? 0 : 0.18, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.backdrop.effect = UIBlurEffect(style: .regular)
            self.menu.alpha = 1
            self.reactionBar.alpha = 1
        } completion: { [weak self] _ in
            guard let self, !self.isDismissing else { return }
            UIAccessibility.post(notification: .screenChanged, argument: self.reactionButtons.first ?? self.actions.first)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or window resize invalidates the extraction coordinates.
        if initialSize != .zero, bounds.size != initialSize { dismiss(animated: false) }
    }

    @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: scroll)
        if !menu.frame.contains(point), !reactionBar.frame.contains(point) { dismiss(animated: true) }
    }
    @objc private func interrupted() { dismiss(animated: false) }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }

    func dismiss(animated: Bool) {
        guard !isDismissing else {
            if !animated { layer.removeAllAnimations(); restoreOnce(); removeFromSuperview() }
            return
        }
        isDismissing = true
        observeNextTouch()
        // The fading overlay must not swallow a new hold or scroll.
        isUserInteractionEnabled = false
        let target = source.map { $0.convert($0.bounds, to: scroll) } ?? targetBubbleFrame
        let finish = { [self] in
            restoreOnce()
            removeFromSuperview()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { finish(); return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.backdrop.effect = nil
            self.menu.alpha = 0
            self.reactionBar.alpha = 0
            self.bubble.transform = .identity
            self.bubble.center = CGPoint(x: target.midX, y: target.midY)
        } completion: { _ in finish() }
    }

    private func restoreOnce() {
        guard !restored else { return }
        restored = true
        if let dismissalTouch {
            dismissalTouch.view?.removeGestureRecognizer(dismissalTouch)
            self.dismissalTouch = nil
        }
        // UIView animations leave the model at its final value, so removing
        // them never writes an overlay position into the returned bubble.
        bubble.layer.removeAllAnimations()
        bubble.transform = .identity
        bubble.isUserInteractionEnabled = true
        source?.accessibilityElementsHidden = false
        restore()
        UIAccessibility.post(notification: .layoutChanged, argument: source)
        let action = afterRestore
        afterRestore = nil
        action?()
    }
}

/// Observes only the next real touch while the menu is closing. It fails at
/// once, so it neither recognizes a gesture nor delays the scroll view's pan.
private final class MessageDismissalTouch: UIGestureRecognizer {
    private let finish: () -> Void

    init(finish: @escaping () -> Void) {
        self.finish = finish
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
        finish()
    }
}

/// The reactions first at hand when a message is held: the ones this device
/// chooses most, then the latest, filled up from the basic set to twenty.
/// All of them are under the chevron.
enum ShumRecentReactions {
    static let shown = 20
    private static let countsKey = "shum.reactions.counts"
    private static let lastKey = "shum.reactions.recent"
    private static let basic = ["heart", "like", "dislike", "laugh", "fire", "coffin", "hundred", "horror",
                                "adore", "wow", "sad", "angry", "hmm", "party", "cool", "eyes",
                                "clap", "wave", "ok", "peace"]

    static var order: [ShumReaction] {
        let defaults = UserDefaults.standard
        let counts = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        let last = defaults.stringArray(forKey: lastKey) ?? []
        let used = counts.keys.sorted {
            (counts[$0] ?? 0, -(last.firstIndex(of: $0) ?? .max)) > (counts[$1] ?? 0, -(last.firstIndex(of: $1) ?? .max))
        }
        var seen = Set<String>()
        return (used + basic)
            .filter { seen.insert($0).inserted }
            .compactMap(ShumReaction.init(rawValue:))
            .prefix(shown)
            .map { $0 }
    }

    static func used(_ reaction: ShumReaction) {
        let defaults = UserDefaults.standard
        var counts = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        counts[reaction.rawValue, default: 0] += 1
        defaults.set(counts, forKey: countsKey)
        let last = defaults.stringArray(forKey: lastKey) ?? []
        defaults.set(Array(([reaction.rawValue] + last.filter { $0 != reaction.rawValue }).prefix(60)), forKey: lastKey)
    }
}

/// One of the places a message can be deleted from, offered in the menu.
struct ShumMenuChoice {
    let title: String
    let action: () -> Void
}
#endif
