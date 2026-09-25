import SwiftUI
import UIKit

/// Compatibility backend for iOS 16–17. UIKit excludes the secure text canvas
/// from system captures. Hosting arbitrary content there is an undocumented
/// workaround, not an Apple-supported screenshot prevention API.
struct ShumSecureCaptureHost<Content: View>: UIViewControllerRepresentable {
    let isEnabled: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> ShumSecureCaptureController<Content> {
        ShumSecureCaptureController(content: content(), isEnabled: isEnabled)
    }

    func updateUIViewController(_ controller: ShumSecureCaptureController<Content>, context: Context) {
        controller.update(content: content(), isEnabled: isEnabled)
    }
}

@MainActor
final class ShumSecureCaptureController<Content: View>: UIViewController {
    let hostingController: UIHostingController<Content>
    let captureView: ShumSecureCaptureView
    private var requestedProtection: Bool
    private var pendingRelease: Task<Void, Never>?
    private var protectionRevision = 0

    init(content: Content, isEnabled: Bool, captureView: ShumSecureCaptureView? = nil) {
        hostingController = UIHostingController(rootView: content)
        self.captureView = captureView ?? ShumSecureCaptureView()
        requestedProtection = isEnabled
        super.init(nibName: nil, bundle: nil)
        self.captureView.setProtectionEnabled(isEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = captureView
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        captureView.install(hostingController.view)
        hostingController.didMove(toParent: self)
    }

    func update(content: Content, isEnabled: Bool) {
        // Never replace the hosting controller on route changes: doing so
        // destroys SwiftUI state and interrupts keyboard/navigation gestures.
        hostingController.rootView = content
        guard requestedProtection != isEnabled else { return }
        requestedProtection = isEnabled
        protectionRevision += 1
        let revision = protectionRevision
        pendingRelease?.cancel()
        pendingRelease = nil
        if isEnabled {
            captureView.setProtectionEnabled(true)
        } else {
            // A path binding changes before the outgoing chat disappears.
            // Keep its pixels protected throughout the navigation transition.
            pendingRelease = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, let self else { return }
                self.releaseProtectionAfterTransition(revision: revision)
            }
        }
    }

    private func releaseProtectionAfterTransition(revision: Int) {
        guard !requestedProtection, protectionRevision == revision else { return }
        if let transition = activeTransition(in: hostingController) {
            let registered = transition.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, !self.requestedProtection,
                      self.protectionRevision == revision, !context.isCancelled else { return }
                self.captureView.setProtectionEnabled(false)
            }
            if registered { return }
        }
        captureView.setProtectionEnabled(false)
    }

    private func activeTransition(in controller: UIViewController) -> UIViewControllerTransitionCoordinator? {
        if let transition = controller.transitionCoordinator { return transition }
        return controller.children.lazy.compactMap { self.activeTransition(in: $0) }.first
    }

    deinit { pendingRelease?.cancel() }

    override var childForStatusBarStyle: UIViewController? { hostingController }
    override var childForStatusBarHidden: UIViewController? { hostingController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { hostingController }
}

@MainActor
final class ShumSecureCaptureView: UIView {
    private let textField = ShumCaptureTextField()
    private var contentView: UIView?
    private(set) var secureCanvas: UIView?
    private(set) var isProtectionEnabled = true
    private var contentConstraints: [NSLayoutConstraint] = []

    var isSecureTextEntry: Bool { textField.isSecureTextEntry }

    init(canvasResolver: @MainActor (UITextField) -> UIView? = { ShumSecureCaptureView.findCanvas(in: $0) }) {
        super.init(frame: .zero)
        backgroundColor = .clear
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.isSecureTextEntry = true
        textField.isAccessibilityElement = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // Keep UIKit's view/layer hierarchy intact; the text field owns its
        // canvas for the entire lifetime of this view.
        textField.layoutIfNeeded()
        secureCanvas = canvasResolver(textField)
        secureCanvas?.isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ content: UIView) {
        contentView?.removeFromSuperview()
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints = []
        contentView = content
        let container = secureCanvas ?? self
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        contentConstraints = [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        NSLayoutConstraint.activate(contentConstraints)
        updateContentVisibility()
    }

    func setProtectionEnabled(_ enabled: Bool) {
        isProtectionEnabled = enabled
        if textField.isSecureTextEntry != enabled {
            textField.isSecureTextEntry = enabled
        }
        updateContentVisibility()
    }

    private func updateContentVisibility() {
        // If UIKit changes its internal canvas, leave the privacy cover visible
        // instead of silently exposing messages in an unprotected fallback.
        contentView?.isHidden = isProtectionEnabled && secureCanvas == nil
    }

    static func findCanvas(in view: UIView) -> UIView? {
        for child in view.subviews {
            if String(describing: type(of: child)) == "_UITextLayoutCanvasView" { return child }
            if let canvas = findCanvas(in: child) { return canvas }
        }
        return nil
    }
}

/// The secure field is only a rendering container. It must never claim input
/// focus or replace the conversation's own text field/accessibility elements.
private final class ShumCaptureTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIKit normally sizes this canvas for a single line of text.
        // A chat needs the full proposed area, including after rotation/keyboard.
        ShumSecureCaptureView.findCanvas(in: self)?.frame = bounds
    }
}
