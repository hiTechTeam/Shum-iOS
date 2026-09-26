import SwiftUI

extension Shum {
    func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .bold)
        ]
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = attributes
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = attributes
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

extension String {
    var localized: String {
        ShumLanguageStore.localizedString(forKey: self)
    }

    static func localizedFormat(_ format: String, _ arguments: Any...) -> String {
        let segments = format.components(separatedBy: "%@")
        guard segments.count > 1 else { return format }

        var result = segments[0]
        for index in segments.indices.dropFirst() {
            let argumentIndex = index - 1
            if arguments.indices.contains(argumentIndex) {
                result += String(describing: arguments[argumentIndex])
            } else {
                result += "%@"
            }
            result += segments[index]
        }
        return result
    }
}

private struct ShumValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value, Value) -> Void

    @State private var previousValue: Value

    init(value: Value, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.action = action
        _previousValue = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onChange(of: value) { newValue in
            let oldValue = previousValue
            previousValue = newValue
            action(oldValue, newValue)
        }
    }
}

extension View {
    func shumOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(ShumValueChangeModifier(value: value, action: action))
    }

    @ViewBuilder
    func shumAlwaysBounce() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.always, axes: .vertical)
        } else {
            self
        }
    }

    @ViewBuilder
    func shumGeometryGroup() -> some View {
        if #available(iOS 17.0, *) {
            geometryGroup()
        } else {
            self
        }
    }

    @ViewBuilder
    func shumReplaceSymbolTransition() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    @ViewBuilder
    func shumInfoListLayout(sectionSpacing: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            listSectionSpacing(sectionSpacing)
                .contentMargins(.vertical, 16, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func shumPresentationBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(color)
        } else {
            self
        }
    }
}
