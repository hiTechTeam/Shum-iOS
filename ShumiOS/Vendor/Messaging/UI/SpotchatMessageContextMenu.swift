#if os(iOS)
import SwiftUI
import UIKit

/// Keeps one live bubble throughout pressing, presentation and dismissal.
/// A system targeted preview would add its own scale, shadow and clipping mask.
struct SpotchatMessageContextMenu<Content: View>: UIViewRepresentable {
    @Environment(\.self) private var environment
    let shape: SpotchatBubbleShape
    let maximumWidth: CGFloat
    let reply: () -> Void
    let copy: () -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat, Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> MessageMenuView { MessageMenuView() }

    func updateUIView(_ view: MessageMenuView, context: Context) {
        view.update(content: AnyView(content().environment(\.self, environment)),
                    shape: shape, reply: reply, copy: copy, dragChanged: dragChanged, dragEnded: dragEnded)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageMenuView, context: Context) -> CGSize? {
        uiView.fittingSize(width: min(proposal.width ?? maximumWidth, maximumWidth))
    }

    static func dismantleUIView(_ uiView: MessageMenuView, coordinator: ()) { uiView.endPresentation() }

    final class MessageMenuView: UIView, UIGestureRecognizerDelegate {
        private let host = UIHostingController(rootView: AnyView(EmptyView()))
        private let bubbleContainer = UIView()
        private var bubbleView: UIView {
            if #available(iOS 26.0, *) { return bubbleContainer }
            return host.view
        }
        private let feedback = UIImpactFeedbackGenerator(style: .medium)
        private var shape = SpotchatBubbleShape(outgoing: false, tail: true)
        private var reply: () -> Void = {}
        private var copy: () -> Void = {}
        private var dragChanged: (CGFloat) -> Void = { _ in }
        private var dragEnded: (CGFloat, Bool) -> Void = { _, _ in }
        private var presentation: SpotchatExtractedMessageMenu?
        private var pendingContent: AnyView?
        private var pressAnimator: UIViewPropertyAnimator?
        private lazy var hold = SpotchatMessageHoldGesture()
        private lazy var replyPanGesture = UIPanGestureRecognizer(target: self, action: #selector(replyPan(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            host.view.backgroundColor = .clear
            host.view.clipsToBounds = false
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            if #available(iOS 26.0, *) {
                // Keep the hosting view attached to the same superview. Moving
                // it directly between hierarchies invalidates its iOS 26 render.
                bubbleContainer.backgroundColor = .clear
                bubbleContainer.addSubview(host.view)
            }
            addSubview(bubbleView)
            hold.delegate = self
            hold.pressing = { [weak self] in self?.beginPress() }
            hold.cancelPress = { [weak self] in self?.cancelPress() }
            hold.activate = { [weak self] in self?.presentMenu() }
            addGestureRecognizer(hold)
            replyPanGesture.delegate = self
            addGestureRecognizer(replyPanGesture)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func endPresentation() {
            replyPanGesture.view?.removeGestureRecognizer(replyPanGesture)
            hold.isEnabled = false
            presentation?.dismiss(animated: false)
            pressAnimator?.stopAnimation(true)
            bubbleView.transform = .identity
        }

        func update(content: AnyView, shape: SpotchatBubbleShape, reply: @escaping () -> Void, copy: @escaping () -> Void, dragChanged: @escaping (CGFloat) -> Void, dragEnded: @escaping (CGFloat, Bool) -> Void) {
            self.shape = shape
            self.reply = reply
            self.copy = copy
            self.dragChanged = dragChanged
            self.dragEnded = dragEnded
            // Delivery/typing updates must not re-layout the extracted message.
            if presentation != nil { pendingContent = content }
            else { host.rootView = content; invalidateIntrinsicContentSize(); setNeedsLayout() }
        }

        func fittingSize(width: CGFloat) -> CGSize {
            if presentation != nil { return bounds.size }
            let size = host.sizeThatFits(in: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachReplyGestureToRow()
        }

        private func attachReplyGestureToRow() {
            var ancestor = superview
            while let view = ancestor {
                if let cell = view as? UITableViewCell {
                    if replyPanGesture.view !== cell.contentView {
                        cell.contentView.addGestureRecognizer(replyPanGesture)
                    }
                    return
                }
                ancestor = view.superview
            }
            if replyPanGesture.view !== self { addGestureRecognizer(replyPanGesture) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachReplyGestureToRow()
            guard presentation == nil else { return }
            bubbleView.bounds = CGRect(origin: .zero, size: bounds.size)
            bubbleView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            if #available(iOS 26.0, *) {
                host.view.bounds = bubbleContainer.bounds
                host.view.center = CGPoint(x: bubbleContainer.bounds.midX, y: bubbleContainer.bounds.midY)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A new press may interrupt the previous bubble's return animation.
            if let window { SpotchatExtractedMessageMenu.finishDismissal(in: window) }
            guard presentation == nil else { return false }
            let point = touch.location(in: self)
            if gestureRecognizer === replyPanGesture {
                // The whole horizontal band belongs to this message. Day labels
                // and delivery captions above/below the bubble are excluded.
                return point.y >= 0 && point.y <= bounds.height
            }
            return shape.path(in: bounds).contains(point)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === replyPanGesture else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = replyPanGesture.velocity(in: window)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.15
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // SwiftUI's scroll recognizer is not always owned by UIScrollView.
            // The hold must fail when a scroll or reply swipe starts.
            gestureRecognizer === replyPanGesture && other !== hold
        }

        @objc private func replyPan(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: window).x
            switch pan.state {
            case .began, .changed: dragChanged(translation)
            case .ended: dragEnded(translation, true)
            case .cancelled, .failed: dragEnded(translation, false)
            default: break
            }
        }

        private func beginPress() {
            feedback.prepare()
            let scale = max(0.7, (bounds.width - 15) / max(1, bounds.width))
            let tension = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.42, y: 0),
                                                  controlPoint2: CGPoint(x: 0.78, y: 0.35))
            animatePress(to: CGAffineTransform(scaleX: scale, y: scale), duration: 0.2, timing: tension)
        }

        private func cancelPress() {
            guard presentation == nil else { return }
            if #available(iOS 26.0, *), pressAnimator == nil, bubbleView.transform.isIdentity { return }
            animatePress(to: .identity, duration: 0.24, timing: UISpringTimingParameters(dampingRatio: 1))
        }

        private func animatePress(to transform: CGAffineTransform, duration: TimeInterval, timing: UITimingCurveProvider) {
            finishPressAnimation()
            let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : duration,
                                                  timingParameters: timing)
            animator.addAnimations { [weak self] in
                self?.bubbleView.transform = transform
            }
            animator.isUserInteractionEnabled = true
            pressAnimator = animator
            animator.startAnimation()
        }

        private func finishPressAnimation() {
            if let animator = pressAnimator, animator.state == .active {
                animator.stopAnimation(false)
                animator.finishAnimation(at: .current)
            }
            pressAnimator = nil
        }

        private func presentMenu() {
            guard presentation == nil, let window, !window.screen.isCaptured else { cancelPress(); return }
            finishPressAnimation()
            let menu = SpotchatExtractedMessageMenu(source: self, bubble: bubbleView, outgoing: shape.outgoing,
                reply: reply, copy: copy) { [weak self] in
                    guard let self else { return }
                    if #available(iOS 26.0, *) {
                        // Restoration can run inside UIKit's dismissal animation.
                        // Do not let that transaction animate layout or pending
                        // SwiftUI updates after the view is back in the list.
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            UIView.performWithoutAnimation { self.restoreBubble() }
                        }
                    } else {
                        self.restoreBubble()
                    }
                }
            presentation = menu
            feedback.impactOccurred(intensity: 0.8)
            menu.present(in: window)
        }

        private func restoreBubble() {
            presentation = nil
            bubbleView.transform = .identity
            addSubview(bubbleView)
            if let content = pendingContent { host.rootView = content; pendingContent = nil }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            layoutIfNeeded()
            if #available(iOS 26.0, *) { host.view.layoutIfNeeded() }
        }
    }
}

/// Remains possible while shrinking, so a normal scroll never waits for a hold.
private final class SpotchatMessageHoldGesture: UIGestureRecognizer {
    var pressing: (() -> Void)?
    var cancelPress: (() -> Void)?
    var activate: (() -> Void)?
    private var startPoint = CGPoint.zero
    private var delay: Timer?
    private var activation: Timer?
    private var didActivate = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first else { state = .failed; return }
        startPoint = touch.location(in: view)
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible else { return }
            self.pressing?()
            let activation = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self, self.state == .possible else { return }
                self.didActivate = true
                self.state = .began
                self.activate?()
            }
            self.activation = activation
            RunLoop.main.add(activation, forMode: .common)
        }
        delay = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !didActivate, let touch = touches.first else { return }
        let point = touch.location(in: view)
        if hypot(point.x - startPoint.x, point.y - startPoint.y) > 8 { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = didActivate ? .ended : .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() {
        delay?.invalidate(); activation?.invalidate()
        delay = nil; activation = nil
        if !didActivate { cancelPress?() }
        didActivate = false
        super.reset()
    }
}
#endif
