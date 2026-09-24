import SwiftUI

/// Highlight follows the finger; release starts navigation immediately.
/// Feedback must never queue navigation behind an animation or a timer.
struct ShumPressButton<Label: View, Style: ButtonStyle>: View {
    let action: () -> Void
    let style: Style
    @ViewBuilder var label: () -> Label
    @State private var lastActivation = -Double.infinity

    var body: some View {
        Button {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastActivation >= 0.12 else { return }
            lastActivation = now
            action()
        } label: {
            label()
        }
        .buttonStyle(style)
        .background(ShumImmediateTouchResponse().allowsHitTesting(false))
    }
}

struct ShumRowPressButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var lastActivation = -Double.infinity

    var body: some View {
        Button {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastActivation >= 0.12 else { return }
            lastActivation = now
            action()
        } label: {
            label()
        }
        .buttonStyle(.automatic)
        .background(ShumImmediateTouchResponse().allowsHitTesting(false))
    }
}

/// SwiftUI List and ScrollView otherwise postpone touch-down while deciding
/// whether a finger will scroll. Keep cancellation enabled for drags/swipes.
private struct ShumImmediateTouchResponse: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.configureScrollViews() }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            configureScrollViews()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            configureScrollViews()
        }
        func configureScrollViews() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.delaysContentTouches = false
                    scroll.canCancelContentTouches = true
                }
                ancestor = view.superview
            }
        }
    }
}
