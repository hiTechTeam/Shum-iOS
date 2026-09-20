#if os(iOS)
import SwiftUI
import UIKit

/// Search stays local and uses the same canonical directory as the chat folders.
enum ShumChatSearch {
    static func matches(_ query: String, name: String, messages: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }
        return ([name] + messages).contains { text in
            words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}

/// The native search presentation supplies focus, keyboard, cancellation and
/// the collapsing navigation drawer. The original list stays mounted underneath
/// results so cancelling preserves its folder and scroll position.
struct ShumChatSearchPresentation: ViewModifier {
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch
    @ObservedObject var runtime: ShumRuntime
    let query: String
    let open: (ShumUIRoute) -> Void

    func body(content: Content) -> some View {
        content
            .background(ShumSearchNavigationLifecycle())
            .allowsHitTesting(!isSearching)
            .accessibilityHidden(isSearching)
            .overlay {
                if isSearching {
                    ShumChatSearchResults(runtime: runtime, query: query) { route in
                        dismissSearch()
                        open(route)
                    }
                }
            }
    }
}

private struct ShumSearchNavigationLifecycle: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var restoresSearchDuringTransition = false

        private var navigationOwner: UIViewController? {
            var owner: UIViewController = self
            while let parent = owner.parent, !(parent is UINavigationController) { owner = parent }
            return owner.parent is UINavigationController ? owner : nil
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            restoresSearchDuringTransition = navigationOwner?.transitionCoordinator != nil
            restoreDirectoryScrollView()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            restoresSearchDuringTransition = false
        }
        override func viewWillDisappear(_ animated: Bool) {
            restoresSearchDuringTransition = false
            super.viewWillDisappear(animated)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            restoreDirectoryScrollView()
            guard restoresSearchDuringTransition,
                  let owner = navigationOwner,
                  owner === navigationController?.topViewController,
                  let search = owner.navigationItem.searchController,
                  !search.isActive, search.searchBar.superview != nil else { return }
            // SwiftUI reattaches the existing search bar during the pop but
            // leaves it transparent until the transition finishes. Restore
            // visibility in that layout pass, alongside the returning screen.
            // UIKit still owns the drawer's geometry and search activation.
            UIView.performWithoutAnimation { search.searchBar.alpha = 1 }
        }

        private func restoreDirectoryScrollView() {
            guard let owner = navigationOwner,
                  owner === navigationController?.topViewController else { return }

            let searchBar = owner.navigationItem.searchController?.searchBar
            let candidates = scrollViews(in: owner.view).filter { scrollView in
                guard scrollView.bounds.height > 100,
                      scrollView.bounds.width > 100,
                      scrollView.isScrollEnabled else { return false }
                if let searchBar, scrollView.isDescendant(of: searchBar) { return false }
                return true
            }
            guard let directory = candidates.max(by: {
                ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
            }) else { return }

            // The conversation controller registers its timeline as the top
            // content scroll view. Register the directory again while popping
            // back so UIKit's native search drawer follows this list's drag.
            owner.setContentScrollView(directory, for: .top)
        }

        private func scrollViews(in view: UIView) -> [UIScrollView] {
            var result = view.subviews.flatMap(scrollViews)
            if let scrollView = view as? UIScrollView { result.append(scrollView) }
            return result
        }
    }
}

private struct ShumChatSearchResults: View {
    @ObservedObject var runtime: ShumRuntime
    let query: String
    let open: (ShumUIRoute) -> Void

    private var results: [ShumDirectoryEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return runtime.directoryEntries.filter { entry in
            entry.belongs(to: .all) && ShumChatSearch.matches(
                query,
                name: entry.peer.name,
                messages: runtime.conversation(entry.id).map(\.text)
            )
        }
    }

    var body: some View {
        ShumDirectoryList(runtime: runtime, folder: .all, entries: results, open: open) {
            EmptyView()
        } empty: {
            VStack(spacing: 8) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Поиск в чатах" : "Ничего не найдено")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("По имени или тексту сообщений")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .multilineTextAlignment(.center)
        }
    }
}
#endif
