import SwiftUI

extension Telescan {
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
        NSLocalizedString(self, comment: "")
    }
}

private struct TelescanValueChangeModifier<Value: Equatable>: ViewModifier {
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
    func telescanOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(TelescanValueChangeModifier(value: value, action: action))
    }

    @ViewBuilder
    func telescanAlwaysBounce() -> some View {
        if #available(iOS 16.4, *) {
            scrollBounceBehavior(.always, axes: .vertical)
        } else {
            self
        }
    }

    @ViewBuilder
    func telescanGeometryGroup() -> some View {
        if #available(iOS 17.0, *) {
            geometryGroup()
        } else {
            self
        }
    }

    @ViewBuilder
    func telescanReplaceSymbolTransition() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    @ViewBuilder
    func telescanInfoListLayout(sectionSpacing: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            listSectionSpacing(sectionSpacing)
                .contentMargins(.vertical, 16, for: .scrollContent)
        } else {
            self
        }
    }

    @ViewBuilder
    func telescanPresentationBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(color)
        } else {
            self
        }
    }
}

struct TelescanContentUnavailableView: View {
    let title: String
    let systemImage: String
    let description: Text?

    init(
        _ title: String,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 17.0, *) {
            if let description {
                ContentUnavailableView(
                    title,
                    systemImage: systemImage,
                    description: description
                )
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.headline)

                if let description {
                    description
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}
