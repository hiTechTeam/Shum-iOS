#if os(iOS)
import SwiftUI

/// Shum's stickers in place of the keyboard: the latest ones and every set
/// in a row on top, the chosen set's stickers five to a row below. A tap
/// sends the sticker. Pulled by its top, or by the chevron, it opens to the
/// top of the screen and back.
struct ShumStickerPanel: View {
    let expanded: Bool
    let toggleExpanded: () -> Void
    let dragChanged: (CGFloat) -> Void
    /// Where the finger would have stopped, for the panel to settle.
    let dragEnded: (CGFloat) -> Void
    let send: (String) -> Void
    @Environment(\.shumThemePalette) private var palette
    @State private var selected: String = ShumRecentStickers.ids.isEmpty
        ? (ShumStickerCatalog.shared.sets.first?.section ?? "") : Self.recentTab

    private static let recentTab = "recent"
    private var catalog: ShumStickerCatalog { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // The sets run to the panel's edge, under a see-through chevron.
                ZStack(alignment: .trailing) {
                    tabs
                    Button(action: toggleExpanded) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                    .accessibilityLabel(expanded ? "Свернуть стикеры".localized : "Развернуть стикеры".localized)
                }
                header
            }
            // The top pulls the panel up and down, as the capsule does.
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        dragChanged(value.translation.height)
                    }
                    .onEnded { value in dragEnded(value.predictedEndTranslation.height) }
            )
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 8) {
                    ForEach(stickers, id: \.id) { sticker in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            ShumRecentStickers.used(sticker.id)
                            send(sticker.id)
                        } label: {
                            Image(uiImage: ShumReactionArt.image(sticker: sticker.id, size: 60))
                                .interpolation(.none)
                                .frame(width: 60, height: 60)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sticker.emoji + " " + sticker.word)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .overlay {
                if stickers.isEmpty {
                    Text("Здесь будут стикеры, которые вы отправляли".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            UnevenTopRounded(radius: 26)
                .fill(Color(.secondarySystemBackground))
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
            Text(String.localizedFormat("Стикеров: %@".localized, "\(stickers.count)"))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tab(Self.recentTab, label: "Недавние".localized) {
                    Image(systemName: "clock")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                ForEach(catalog.sets, id: \.section) { set in
                    tab(set.section, label: set.title.localized) {
                        Image(uiImage: ShumReactionArt.icon(set: set.section, size: 32))
                            .interpolation(.none)
                    }
                }
            }
            .padding(.leading, 12)
            // The last set can still come out from under the chevron.
            .padding(.trailing, 62)
            .padding(.vertical, 10)
        }
    }

    private func tab<Label: View>(_ id: String, label: String, @ViewBuilder content: () -> Label) -> some View {
        Button {
            selected = id
        } label: {
            content()
                .frame(width: 44, height: 44)
                .background {
                    if selected == id {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.accent.opacity(0.22))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }

    private var title: String {
        if selected == Self.recentTab { return "Недавние".localized }
        return catalog.sets.first { $0.section == selected }?.title.localized ?? ""
    }

    private var stickers: [ShumStickerCatalog.Sticker] {
        if selected == Self.recentTab {
            return ShumRecentStickers.ids.compactMap(catalog.sticker)
        }
        return catalog.sets.first { $0.section == selected }?.kinds ?? []
    }
}

/// The back button with how many messages wait in the other chats, in one
/// control as in Telegram. It stands in for the system one, so the swipe
/// back from the edge is kept on by `ShumSwipeBack`.
struct ShumBackButton: View {
    let count: Int
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.primary, in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(count > 0
            ? String.localizedFormat("Непрочитанных в других чатах: %@".localized, "\(count)")
            : "Назад".localized)
    }
}

/// Keeps the swipe back from the screen's edge where the back button is the
/// app's own: the system turns it off together with its button.
struct ShumSwipeBack: UIViewControllerRepresentable {
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var previous: UIGestureRecognizerDelegate?
        private weak var gesture: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer,
                  gesture.delegate !== self else { return }
            previous = gesture.delegate
            self.gesture = gesture
            gesture.delegate = self
            gesture.isEnabled = true
        }

        /// The system's own handling comes back once the chat is gone.
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let gesture, gesture.delegate === self else { return }
            gesture.delegate = previous
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}
}

/// The capsule's button for stickers in place of the keyboard, and back.
struct ShumStickersButton: View {
    let open: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "keyboard" : "face.smiling.inverse")
                .font(.system(size: open ? 19 : 23, weight: .regular))
                .foregroundStyle(open ? accent : Color(.systemGray2))
                .frame(width: 38, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Клавиатура".localized : "Стикеры".localized)
    }
}

/// Stickers this device sent, the latest first.
enum ShumRecentStickers {
    private static let key = "shum.stickers.recent"
    private static let limit = 24

    static var ids: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { ShumStickerCatalog.shared.sticker($0) != nil }
    }

    static func used(_ id: String) {
        UserDefaults.standard.set(Array(([id] + ids.filter { $0 != id }).prefix(limit)), forKey: key)
    }
}

/// Rounded at the top only, square at the screen's bottom edge.
private struct UnevenTopRounded: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
#endif
