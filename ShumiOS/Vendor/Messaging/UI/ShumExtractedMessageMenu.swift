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
    private var reactionButtons: [UIButton] = []
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
         cancelSending: (() -> Void)?, reaction: ShumReaction?, react: ((ShumReaction) -> Void)?,
         restore: @escaping () -> Void) {
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
            actions.append(makeAction("Отменить отправку".localized, symbol: "xmark.circle",
                                      color: .systemRed, action: cancelSending))
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
            reactionButtons = ShumReaction.allCases.map { option in
                makeReaction(option, selected: option == reaction) { react(option) }
            }
            reactionButtons.forEach { reactionBar.contentView.addSubview($0) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIScreen.capturedDidChangeNotification, object: nil)
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

    private func makeAction(_ title: String, symbol: String, color: UIColor = .label,
                            action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        configuration.imagePadding = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        configuration.baseForegroundColor = color
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .preferredFont(forTextStyle: .body)
            return result
        }
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = color
            button.backgroundColor = button.isHighlighted ? .tertiarySystemFill : .clear
        }
        button.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
            action()
        }, for: .touchUpInside)
        return button
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
            self?.afterRestore = action
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        return button
    }

    func present(in window: UIWindow) {
        Self.finishDismissal(in: window)
        guard let source, let surface = window.rootViewController?.view else { restoreOnce(); return }
        frame = surface.convert(window.bounds, from: window)
        initialSize = bounds.size
        backdrop.frame = bounds
        scroll.frame = bounds
        let sourceFrame = source.convert(source.bounds, to: window)
        let rowHeight = max(48, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
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
        reactionBar.frame = CGRect(origin: CGPoint(x: aligned(barSize.width), y: bubbleFrame.minY - barRoom), size: barSize)
        reactionBar.layer.cornerRadius = barSize.height / 2
        for (index, button) in reactionButtons.enumerated() {
            button.frame = CGRect(x: inset.left + CGFloat(index) * (Self.reactionSize + Self.reactionSpacing),
                                  y: inset.top, width: Self.reactionSize, height: Self.reactionSize)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, menu.frame.maxY + window.safeAreaInsets.bottom + 12))
        targetBubbleFrame = bubbleFrame

        surface.addSubview(self)
        source.accessibilityElementsHidden = true
        // Moving the existing view also preserves its SwiftUI environment,
        // including capture redaction, palette and text measurements.
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
#endif
