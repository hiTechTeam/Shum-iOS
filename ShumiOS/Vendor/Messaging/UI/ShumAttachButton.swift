#if os(iOS)
import SwiftUI
import UIKit

/// "+" in the composer with the system menu: its own animation, material
/// and haptics. While the menu is open the button turns into a green close
/// button, as in the design.
struct ShumAttachButton: UIViewRepresentable {
    let accent: UIColor
    let accentForeground: UIColor
    let choosePhoto: () -> Void
    let takePhoto: (() -> Void)?

    /// Holds the latest actions, so the menu itself is built once: a menu
    /// set again while it is open redraws it, which flickers.
    final class Coordinator {
        var choosePhoto: () -> Void = {}
        var takePhoto: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Button {
        let button = Button(accent: accent, accentForeground: accentForeground)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "shum.attach"
        button.setContentHuggingPriority(.required, for: .horizontal)
        let coordinator = context.coordinator
        var actions = [UIAction(title: "Фото".localized, image: UIImage(systemName: "photo")) { _ in
            coordinator.choosePhoto()
        }]
        if takePhoto != nil {
            actions.append(UIAction(title: "Камера".localized, image: UIImage(systemName: "camera")) { _ in
                coordinator.takePhoto?()
            })
        }
        button.menu = UIMenu(children: actions)
        // Listed from the button up, as it opens above the composer.
        button.preferredMenuElementOrder = .fixed
        return button
    }

    func updateUIView(_ button: Button, context: Context) {
        context.coordinator.choosePhoto = choosePhoto
        context.coordinator.takePhoto = takePhoto
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Button, context: Context) -> CGSize? {
        CGSize(width: 46, height: 46)
    }

    final class Button: UIButton {
        /// "+" and the green close button are layers that cross over in step
        /// with the menu's own animation; swapping the button's configuration
        /// instead redraws it at once and jerks.
        private let plus = UIImageView(image: UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)))
        private let close = UIView()

        init(accent: UIColor, accentForeground: UIColor) {
            super.init(frame: .zero)
            plus.tintColor = .secondaryLabel
            close.backgroundColor = accent
            close.layer.cornerRadius = 18
            let mark = UIImageView(image: UIImage(
                systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))
            mark.tintColor = accentForeground
            close.addSubview(mark)
            mark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: close.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            ])
            for view in [close, plus] as [UIView] {
                view.isUserInteractionEnabled = false
                addSubview(view)
            }
            show(open: false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private func show(open: Bool) {
            let turn = CGAffineTransform(rotationAngle: .pi / 4)
            plus.alpha = open ? 0 : 1
            plus.transform = open ? turn.scaledBy(x: 0.6, y: 0.6) : .identity
            close.alpha = open ? 1 : 0
            close.transform = open ? .identity : turn.inverted().scaledBy(x: 0.6, y: 0.6)
            accessibilityLabel = open ? "Закрыть вложения".localized : "Вложения".localized
        }

        private func animate(open: Bool, with animator: UIContextMenuInteractionAnimating?) {
            if let animator {
                animator.addAnimations { self.show(open: open) }
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85,
                               initialSpringVelocity: 0, options: [.allowUserInteraction]) { self.show(open: open) }
            }
        }

        /// The menu grows out of a clear circle as tall as the capsule, laid
        /// over the button: the button sits in the capsule's rounded end, so
        /// the menu's corner fits it, and the button itself is never hidden
        /// while the menu opens and closes.
        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            capsuleEnd()
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            capsuleEnd()
        }

        /// A clear circle the size of the button: the menu grows out of it,
        /// and the system hides it instead of the "+".
        private let menuSource: UIView = {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            return view
        }()

        override func layoutSubviews() {
            super.layoutSubviews()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            plus.bounds.size = plus.intrinsicContentSize
            plus.center = center
            close.bounds.size = CGSize(width: 36, height: 36)
            close.center = center
            if menuSource.superview == nil { insertSubview(menuSource, at: 0) }
            if #available(iOS 26.0, *) {
                // iOS 26 lays the menu over its source: from just above the
                // capsule it leaves the green close button in sight, as on
                // earlier iOS.
                menuSource.frame = bounds.offsetBy(dx: 0, dy: -(bounds.height + 6))
            } else {
                menuSource.frame = bounds
            }
        }

        private func capsuleEnd() -> UITargetedPreview {
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(ovalIn: menuSource.bounds)
            return UITargetedPreview(view: menuSource, parameters: parameters)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: UIContextMenuInteractionAnimating?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            animate(open: true, with: animator)
        }

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willEndFor configuration: UIContextMenuConfiguration,
                                             animator: UIContextMenuInteractionAnimating?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            animate(open: false, with: animator)
        }
    }
}
#endif
