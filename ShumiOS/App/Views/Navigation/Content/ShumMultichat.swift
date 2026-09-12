import SwiftUI
import UIKit

/// A tab-bar action: shouldSelect prevents the native selection pill from moving.
struct ShumMultichatTabAction: UIViewControllerRepresentable {
    let action: () -> Void
    func makeUIViewController(context: Context) -> ObserverController {
        let controller = ObserverController()
        controller.action = action
        return controller
    }
    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.action = action
        controller.attach()
    }
    final class ObserverController: UIViewController, UITabBarControllerDelegate {
        var action: (() -> Void)?
        private weak var previousDelegate: UITabBarControllerDelegate?
        private weak var observedTabs: UITabBarController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        func attach() {
            var ancestor: UIViewController = self
            while let parent = ancestor.parent { ancestor = parent }
            func findTabs(_ controller: UIViewController) -> UITabBarController? {
                if let tabs = controller as? UITabBarController { return tabs }
                return controller.children.lazy.compactMap { findTabs($0) }.first
            }
            guard let tabs = tabBarController ?? findTabs(ancestor) else { return }
            if tabs.delegate !== self {
                previousDelegate = tabs.delegate
                observedTabs = tabs
                tabs.delegate = self
            }
        }
        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if tabBarController.viewControllers?.first === viewController {
                action?()
                return false
            }
            return previousDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }
        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previousDelegate?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

enum ShumMultichatIcon {
    // Two overlapping pixel speech bubbles, drawn on a 14×14 grid.
    static let image: UIImage = {
        let rows = [
            "00000000000000", "00111111110000", "01100000011000",
            "01000000001000", "01000000001000", "01000000001000",
            "01111111011000", "00100111100000", "00101000000100",
            "00010000000100", "00001111111100", "00000000101000",
            "00000000010000", "00000000000000"
        ]
        return UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
            UIColor.systemGreen.withAlphaComponent(0.65).setFill()
            for (y, row) in rows.enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "1" {
                    context.fill(CGRect(x: x * 2, y: y * 2, width: 2, height: 2))
                }
            }
        }.withRenderingMode(.alwaysOriginal)
    }()
}

struct ShumMultichatPlaceholder: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(uiImage: ShumMultichatIcon.image)
                    .interpolation(.none).resizable().frame(width: 56, height: 56)
                Text("Общий чат рядом").font(.title3.weight(.semibold))
                Text("Здесь будет общий чат по Bluetooth.\nСкоро в Shum.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Мультичат").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(.primary).accessibilityLabel("Закрыть")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
