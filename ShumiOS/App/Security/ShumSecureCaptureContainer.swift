import SwiftUI
import UIKit

/// Keeps the live SwiftUI hierarchy inside UIKit's protected text canvas.
///
/// iOS does not expose a public screenshot-protection API for arbitrary views.
/// A secure text field, however, owns a canvas that the system excludes from
/// captured output. The app content is hosted inside that canvas, while a
/// neutral Shum cover remains behind it for screenshots and recordings.
struct ShumSecureCaptureContainer<Content: View>: UIViewControllerRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> ShumSecureCaptureViewController<Content> {
        ShumSecureCaptureViewController(content: content)
    }

    func updateUIViewController(
        _ viewController: ShumSecureCaptureViewController<Content>,
        context: Context
    ) {
        viewController.update(content: content)
    }
}

@MainActor
final class ShumSecureCaptureViewController<Content: View>: UIViewController {
    private let secureTextField = ShumSecureTextField(frame: .zero)
    private let coverController = UIHostingController<AnyView>(
        rootView: AnyView(
            ShumPrivacyCover()
                .blur(radius: 18, opaque: true)
        )
    )
    private let contentController: UIHostingController<Content>

    private var contentHasBeenInstalled = false

    init(content: Content) {
        contentController = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor(named: "ls-Background") ?? .black
        installCover()
        installSecureTextField()
        installContentIfPossible()

        DispatchQueue.main.async { [weak self] in
            self?.installContentIfPossible()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.installUnprotectedFallbackIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // The protected canvas is created lazily on some iOS releases.
        installContentIfPossible()
    }

    func update(content: Content) {
        contentController.rootView = content
    }

    private func installCover() {
        addChild(coverController)
        let cover = coverController.view!
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.backgroundColor = .clear
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        coverController.didMove(toParent: self)
    }

    private func installSecureTextField() {
        secureTextField.translatesAutoresizingMaskIntoConstraints = false
        secureTextField.backgroundColor = .clear
        secureTextField.borderStyle = .none
        secureTextField.textColor = .clear
        secureTextField.tintColor = .clear
        secureTextField.isSecureTextEntry = true
        secureTextField.text = " "
        secureTextField.isAccessibilityElement = false
        view.addSubview(secureTextField)

        NSLayoutConstraint.activate([
            secureTextField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureTextField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureTextField.topAnchor.constraint(equalTo: view.topAnchor),
            secureTextField.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        secureTextField.layoutIfNeeded()
    }

    private func installContentIfPossible() {
        guard !contentHasBeenInstalled,
              let protectedCanvas = findProtectedCanvas(in: secureTextField) else {
            return
        }

        installContent(in: protectedCanvas)
    }

    private func installUnprotectedFallbackIfNeeded() {
        guard !contentHasBeenInstalled else { return }

        // UIKit's internal canvas name may change on a future iOS release.
        // Keep Shum usable in that case instead of leaving a blank screen.
        secureTextField.removeFromSuperview()
        installContent(in: view)
    }

    private func installContent(in container: UIView) {
        addChild(contentController)
        let content = contentController.view!
        content.translatesAutoresizingMaskIntoConstraints = false
        content.backgroundColor = .clear
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        contentController.didMove(toParent: self)
        contentHasBeenInstalled = true
    }

    private func findProtectedCanvas(in root: UIView) -> UIView? {
        for child in root.subviews {
            let className = String(describing: type(of: child))
            if className.contains("CanvasView") {
                return child
            }

            if let nested = findProtectedCanvas(in: child) {
                return nested
            }
        }

        return nil
    }
}

private final class ShumSecureTextField: UITextField {
    override var canBecomeFirstResponder: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}
