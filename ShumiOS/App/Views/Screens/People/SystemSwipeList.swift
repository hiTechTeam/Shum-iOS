import SwiftUI
import UIKit

extension Color {
    static var peopleListBackground: Color {
        return Color(uiColor: .systemBackground)
    }

    static var profileRowSwipeSurface: Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? .tertiarySystemBackground
                    : .secondarySystemBackground
            }
        )
    }
}

final class SavedPeopleStateStore: ObservableObject {
    static let shared = SavedPeopleStateStore()

    private let identifiersStorageKey = "savedPeopleProfileIDs"
    private let profilesStorageKey = "savedPeopleProfiles"
    private let saveInformationSuppressedKey =
        "savedProfileInformationSuppressed"
    @Published private var savedIDs: Set<UUID>
    @Published private(set) var users: [NearbyUser]

    private init() {
        let storedIDs = Set(
            UserDefaults.standard
                .stringArray(forKey: identifiersStorageKey)?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
        let decodedUsers = UserDefaults.standard
            .data(forKey: profilesStorageKey)
            .flatMap { try? JSONDecoder().decode([NearbyUser].self, from: $0) }
            ?? []
        var seenIDs = Set<UUID>()
        let uniqueUsers = decodedUsers.filter {
            seenIDs.insert($0.id).inserted
        }
        users = uniqueUsers
        savedIDs = storedIDs.union(uniqueUsers.map(\.id))
    }

    func contains(_ id: UUID) -> Bool {
        savedIDs.contains(id)
    }

    var count: Int {
        savedIDs.count
    }

    var shouldShowSaveInformation: Bool {
        !UserDefaults.standard.bool(forKey: saveInformationSuppressedKey)
    }

    func suppressSaveInformation() {
        UserDefaults.standard.set(
            true,
            forKey: saveInformationSuppressedKey
        )
    }

    @discardableResult
    func toggle(_ user: NearbyUser) -> Bool {
        let isSaved: Bool

        if savedIDs.remove(user.id) != nil {
            users.removeAll { $0.id == user.id }
            isSaved = false
        } else {
            savedIDs.insert(user.id)
            users.append(user)
            isSaved = true
        }

        persist()
        return isSaved
    }

    func remove(_ user: NearbyUser) {
        guard savedIDs.contains(user.id) else { return }
        _ = toggle(user)
    }

    func removeAll() {
        savedIDs.removeAll()
        users.removeAll()
        UserDefaults.standard.removeObject(forKey: identifiersStorageKey)
        UserDefaults.standard.removeObject(forKey: profilesStorageKey)
        UserDefaults.standard.removeObject(forKey: saveInformationSuppressedKey)
    }

    func refreshProfile(_ user: NearbyUser) {
        guard savedIDs.contains(user.id) else { return }

        if let index = users.firstIndex(where: { $0.id == user.id }) {
            guard users[index] != user else { return }
            users[index] = user
        } else {
            users.append(user)
        }

        persist()
    }

    private func persist() {
        UserDefaults.standard.set(
            savedIDs.map(\.uuidString).sorted(),
            forKey: identifiersStorageKey
        )
        UserDefaults.standard.set(
            try? JSONEncoder().encode(users),
            forKey: profilesStorageKey
        )
    }
}

private struct SavedProfileInformationAlertModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert(
            Inc.NearbyProfile.savedInformationTitle.localized,
            isPresented: $isPresented
        ) {
            Button(Inc.NearbyProfile.acknowledge.localized) { }

            Button(
                Inc.NearbyProfile.savedInformationDoNotShow.localized
            ) {
                SavedPeopleStateStore.shared.suppressSaveInformation()
            }
        } message: {
            Text(Inc.NearbyProfile.savedInformationMessage.localized)
        }
    }
}

extension View {
    func savedProfileInformationAlert(
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(
            SavedProfileInformationAlertModifier(
                isPresented: isPresented
            )
        )
    }
}

protocol SavedPeopleListItem: Identifiable where ID == UUID {
    var savedProfile: NearbyUser { get }
}

extension NearbyUser: SavedPeopleListItem {
    var savedProfile: NearbyUser { self }
}

extension EncounterHistoryEntry: SavedPeopleListItem {
    var savedProfile: NearbyUser { user }
}

struct NativeSwipeInteractionRow<Content: View>: View {
    @State private var isSwipeActive = false
    @State private var suppressPersistentSurface = false

    let persistentSurfaceColor: Color?
    let hidesPersistentSurfaceAfterSwipe: Bool
    let content: Content

    init(
        persistentSurfaceColor: Color? = nil,
        hidesPersistentSurfaceAfterSwipe: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.persistentSurfaceColor = persistentSurfaceColor
        self.hidesPersistentSurfaceAfterSwipe = hidesPersistentSurfaceAfterSwipe
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if #available(iOS 26.0, *) {
                    activeSurfaceColor
                        .opacity(isSurfaceVisible ? 1 : 0)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: isSwipeActive ? 26 : 0,
                                style: .continuous
                            )
                        )
                } else if let visiblePersistentSurfaceColor {
                    visiblePersistentSurfaceColor
                }

                if #available(iOS 26.0, *) {
                    NativeSwipeOffsetProbe(isActive: $isSwipeActive)
                        .allowsHitTesting(false)
                }
            }
            .animation(
                .easeOut(duration: isSwipeActive ? 0.16 : 0.3),
                value: isSwipeActive
            )
            .shumOnChange(of: isSwipeActive) { wasActive, isActive in
                if !isActive, wasActive,
                   persistentSurfaceColor != nil,
                   hidesPersistentSurfaceAfterSwipe {
                    withAnimation(.easeOut(duration: 0.3)) {
                        suppressPersistentSurface = true
                    }
                }
            }
            .shumOnChange(of: hasPersistentSurface) { _, hasSurface in
                guard hasSurface, !isSwipeActive else { return }
                suppressPersistentSurface = false
            }
    }

    private var hasPersistentSurface: Bool {
        persistentSurfaceColor != nil
    }

    private var visiblePersistentSurfaceColor: Color? {
        suppressPersistentSurface ? nil : persistentSurfaceColor
    }

    private var activeSurfaceColor: Color {
        visiblePersistentSurfaceColor ?? .profileRowSwipeSurface
    }

    private var isSurfaceVisible: Bool {
        visiblePersistentSurfaceColor != nil || isSwipeActive
    }
}

private struct NativeSwipeOffsetProbe: UIViewRepresentable {
    @Binding var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: $isActive)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.isActive = $isActive
        context.coordinator.attach(to: view)
    }

    static func dismantleUIView(
        _ view: UIView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        private struct SwipeOffsets {
            let model: CGFloat
            let presentation: CGFloat

            var visible: CGFloat {
                max(model, presentation)
            }

            var isSettled: Bool {
                model < 1 && presentation < 1
            }
        }

        var isActive: Binding<Bool>

        private weak var probeView: UIView?
        private var displayLink: CADisplayLink?
        private var restingOriginX: CGFloat?
        private var previousOffset: CGFloat = 0
        private var maximumOffset: CGFloat = 0
        private var isReturning = false

        init(isActive: Binding<Bool>) {
            self.isActive = isActive
        }

        func attach(to view: UIView) {
            guard probeView !== view || displayLink == nil else { return }

            stop()
            probeView = view
            restingOriginX = nil
            previousOffset = 0
            maximumOffset = 0
            isReturning = false

            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(observeHorizontalOffset)
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 15,
                maximum: 30,
                preferred: 30
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            restingOriginX = nil
            previousOffset = 0
            maximumOffset = 0
            isReturning = false
        }

        @objc private func observeHorizontalOffset() {
            guard let probeView,
                  probeView.window != nil,
                  let scrollView = enclosingScrollView(for: probeView) else {
                return
            }

            let modelOriginX = probeView.convert(.zero, to: scrollView).x

            guard let restingOriginX else {
                self.restingOriginX = modelOriginX
                return
            }

            let offsets = swipeOffsets(
                for: probeView,
                in: scrollView,
                restingOriginX: restingOriginX
            )
            let offset = offsets.visible
            let isTouchActive = hasActivePanGesture(from: probeView)

            if offsets.isSettled, !isTouchActive {
                self.restingOriginX = modelOriginX
                previousOffset = 0
                maximumOffset = 0
                isReturning = false
                setActive(false)
                return
            }

            if !isActive.wrappedValue {
                if offset > 4, !isReturning || isTouchActive {
                    isReturning = false
                    maximumOffset = offset
                    setActive(true)
                }

                previousOffset = offset
                return
            }

            maximumOffset = max(maximumOffset, offset)

            let hasStartedReturning = offsets.model < 1
                && maximumOffset > 4
                && offset < previousOffset - 0.5

            if hasStartedReturning, !isTouchActive {
                isReturning = true
                setActive(false)
            }

            previousOffset = offset
        }

        private func swipeOffsets(
            for probeView: UIView,
            in scrollView: UIScrollView,
            restingOriginX: CGFloat
        ) -> SwipeOffsets {
            let modelOriginX = probeView.convert(.zero, to: scrollView).x
            let modelOffset = abs(modelOriginX - restingOriginX)

            guard let presentationLayer = probeView.layer.presentation()
            else {
                return SwipeOffsets(
                    model: modelOffset,
                    presentation: modelOffset
                )
            }

            let scrollLayer = scrollView.layer.presentation()
                ?? scrollView.layer
            let presentationOriginX = presentationLayer.convert(
                .zero,
                to: scrollLayer
            ).x

            return SwipeOffsets(
                model: modelOffset,
                presentation: abs(presentationOriginX - restingOriginX)
            )
        }

        private func hasActivePanGesture(from view: UIView) -> Bool {
            var currentView: UIView? = view

            while let candidate = currentView {
                let hasActivePan = candidate.gestureRecognizers?.contains {
                    recognizer in
                    guard recognizer is UIPanGestureRecognizer else {
                        return false
                    }

                    return recognizer.state == .began
                        || recognizer.state == .changed
                } ?? false

                if hasActivePan {
                    return true
                }

                currentView = candidate.superview
            }

            return false
        }

        private func enclosingScrollView(for view: UIView) -> UIScrollView? {
            sequence(first: view.superview, next: { $0?.superview })
                .compactMap { $0 as? UIScrollView }
                .first
        }

        private func setActive(_ value: Bool) {
            guard isActive.wrappedValue != value else { return }
            isActive.wrappedValue = value
        }
    }
}
