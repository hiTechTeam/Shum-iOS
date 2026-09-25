#if os(iOS)
import UIKit

/// Presents the original hosting view above a separate blur. The bubble has no
/// snapshot, extra fill, shadow, mask or scale greater than one.
final class ShumExtractedMessageMenu: UIView {
    private weak var source: UIView?
    private let bubble: UIView
    private let restore: () -> Void
    private let outgoing: Bool
    private let backdrop = UIVisualEffectView()
    private let scroll = UIScrollView()
    private let menu = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private var actions: [UIButton] = []
    private let nativeAnchor = MessageMenuAnchor(type: .custom)
    private var nativeMenuIsVisible = false
    private var usesNativeMenu: Bool { if #available(iOS 17.4, *) { return true }; return false }
    private var isDismissing = false
    private var restored = false
    private var presentationStarted = false
    private var initialSize = CGSize.zero
    private var targetBubbleFrame = CGRect.zero
    private var dismissalTouch: MessageDismissalTouch?

    init(source: UIView, bubble: UIView, outgoing: Bool,
         reply: @escaping () -> Void, copy: @escaping () -> Void, restore: @escaping () -> Void) {
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
        if usesNativeMenu {
            nativeAnchor.backgroundColor = .clear
            nativeAnchor.showsMenuAsPrimaryAction = true
            nativeAnchor.accessibilityElementsHidden = true
            let foreground = UIColor.label.resolvedColor(with: source.traitCollection)
            func icon(_ name: String) -> UIImage? {
                UIImage(systemName: name)?.withTintColor(foreground, renderingMode: .alwaysOriginal)
            }
            nativeAnchor.menu = UIMenu(children: [
                UIAction(title: "Ответить".localized, image: icon("arrowshape.turn.up.left")) { _ in reply() },
                UIAction(title: "Скопировать".localized, image: icon("doc.on.doc")) { _ in copy() }
            ])
            nativeAnchor.onDisplay = { [weak self] in
                self?.nativeMenuIsVisible = true
                self?.animatePresentation()
            }
            nativeAnchor.onEnd = { [weak self] animator in self?.nativeMenuEnding(animator: animator) }
            scroll.addSubview(nativeAnchor)
        } else {
            // iOS 16–17.3 has no public programmatic primary-menu presentation.
            // Retain the existing menu there without changing its bubble behavior.
            menu.layer.cornerRadius = 14
            menu.clipsToBounds = true
            menu.alpha = 0
            scroll.addSubview(menu)
            actions = [makeAction("Ответить".localized, symbol: "arrowshape.turn.up.left", action: reply),
                       makeAction("Скопировать".localized, symbol: "doc.on.doc", action: copy)]
            actions.forEach { menu.contentView.addSubview($0) }
            let separator = UIView()
            separator.backgroundColor = .separator
            separator.tag = 1
            menu.contentView.addSubview(separator)
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

    private func makeAction(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        configuration.imagePadding = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = .preferredFont(forTextStyle: .body)
            return result
        }
        button.configuration = configuration
        button.contentHorizontalAlignment = .leading
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = .label
            button.backgroundColor = button.isHighlighted ? .tertiarySystemFill : .clear
        }
        button.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
            action()
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
        let menuSize = CGSize(width: min(250, bounds.width - 32), height: rowHeight * 2)
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
        bubbleFrame.origin.y = max(top, min(sourceFrame.minY, bottom - menuRoom - bubbleFrame.height))
        let menuY = bubbleFrame.maxY + 8
        let menuX = max(16, min(outgoing ? bubbleFrame.maxX - menuSize.width : bubbleFrame.minX, bounds.width - menuSize.width - 16))
        menu.frame = CGRect(origin: CGPoint(x: menuX, y: menuY), size: menuSize)
        for (index, button) in actions.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: menuSize.width, height: rowHeight)
        }
        menu.contentView.viewWithTag(1)?.frame = CGRect(x: 0, y: rowHeight, width: menuSize.width, height: 1 / window.screen.scale)
        scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, menu.frame.maxY + window.safeAreaInsets.bottom + 12))
        targetBubbleFrame = bubbleFrame
        nativeAnchor.frame = CGRect(x: outgoing ? bubbleFrame.maxX - 1 : bubbleFrame.minX,
                                    y: menuY, width: 1, height: 1)

        surface.addSubview(self)
        source.accessibilityElementsHidden = true
        // Moving the existing view also preserves its SwiftUI environment,
        // including capture redaction, palette and text measurements.
        scroll.addSubview(bubble)
        bubble.bounds = CGRect(origin: .zero, size: sourceFrame.size)
        bubble.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        bubble.isUserInteractionEnabled = false
        // The anchor is already at the final location. Opening the native menu
        // must not wait for the bubble to travel there.
        layoutIfNeeded()
        if #available(iOS 17.4, *) { nativeAnchor.performPrimaryAction() }
        else { animatePresentation() }
    }

    private func animatePresentation() {
        guard !isDismissing, !presentationStarted else { return }
        presentationStarted = true
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: reducedMotion ? 0 : 0.28, delay: 0,
                       usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.bubble.transform = .identity
            self.bubble.center = CGPoint(x: self.targetBubbleFrame.midX, y: self.targetBubbleFrame.midY)
        }
        UIView.animate(withDuration: reducedMotion ? 0 : 0.18, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.backdrop.effect = UIBlurEffect(style: .regular)
            if !self.usesNativeMenu { self.menu.alpha = 1 }
        } completion: { [weak self] _ in
            guard let self, !self.isDismissing else { return }
            if !self.usesNativeMenu { UIAccessibility.post(notification: .screenChanged, argument: self.actions.first) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or window resize invalidates the extraction coordinates.
        if initialSize != .zero, bounds.size != initialSize { dismiss(animated: false) }
    }

    @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
        if usesNativeMenu { dismiss(animated: true); return }
        if !menu.frame.contains(recognizer.location(in: scroll)) { dismiss(animated: true) }
    }
    @objc private func interrupted() { dismiss(animated: false) }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }

    func dismiss(animated: Bool) {
        guard !isDismissing else {
            if !animated { layer.removeAllAnimations(); restoreOnce(); removeFromSuperview() }
            return
        }
        if nativeMenuIsVisible {
            nativeAnchor.contextMenuInteraction?.dismissMenu()
            if animated { return }
        }
        isDismissing = true
        observeNextTouch()
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
            self.bubble.transform = .identity
            self.bubble.center = CGPoint(x: target.midX, y: target.midY)
        } completion: { _ in finish() }
    }

    private func nativeMenuEnding(animator: UIContextMenuInteractionAnimating?) {
        nativeMenuIsVisible = false
        guard !isDismissing else { return }
        isDismissing = true
        observeNextTouch()
        // The fading overlay must not swallow a new hold or scroll.
        isUserInteractionEnabled = false
        let target = source.map { $0.convert($0.bounds, to: scroll) } ?? targetBubbleFrame
        let changes = {
            guard !self.restored else { return }
            self.backdrop.effect = nil
            self.bubble.transform = .identity
            self.bubble.center = CGPoint(x: target.midX, y: target.midY)
        }
        let finish = {
            self.restoreOnce()
            self.removeFromSuperview()
        }
        if let animator { animator.addAnimations(changes); animator.addCompletion(finish) }
        else { changes(); finish() }
    }

    private func restoreOnce() {
        guard !restored else { return }
        restored = true
        if let dismissalTouch {
            dismissalTouch.view?.removeGestureRecognizer(dismissalTouch)
            self.dismissalTouch = nil
        }
        bubble.layer.removeAllAnimations()
        bubble.transform = .identity
        bubble.isUserInteractionEnabled = true
        source?.accessibilityElementsHidden = false
        restore()
        UIAccessibility.post(notification: .layoutChanged, argument: source)
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

/// An empty, already-positioned anchor supplies only the native action menu.
/// UIKit never creates a preview or a second surface for the message itself.
private final class MessageMenuAnchor: UIButton {
    var onDisplay: (() -> Void)?
    var onEnd: ((UIContextMenuInteractionAnimating?) -> Void)?
    override func menuAttachmentPoint(for configuration: UIContextMenuConfiguration) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY)
    }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.menu }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onDisplay?()
    }
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onEnd?(animator)
    }
}
#endif
