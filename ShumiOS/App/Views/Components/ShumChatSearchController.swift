import SwiftUI
import UIKit

/// Keeps native search presentation in one controller, including its dismissal transition.
struct ShumChatSearchController: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.text = $text
        controller.presented = $isPresented
        controller.wantsSearch = isPresented
        controller.synchronize()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detach()
    }

    final class Controller: UIViewController, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate {
        var text: Binding<String> = .constant("")
        var presented: Binding<Bool> = .constant(false)
        var wantsSearch = false
        private var isDismissing = false
        private weak var host: UIViewController?
        private lazy var search: UISearchController = {
            let search = UISearchController(searchResultsController: nil)
            search.obscuresBackgroundDuringPresentation = false
            search.hidesNavigationBarDuringPresentation = false
            search.searchResultsUpdater = self
            search.delegate = self
            search.searchBar.delegate = self
            search.searchBar.placeholder = "Поиск"
            search.searchBar.autocapitalizationType = .none
            search.searchBar.setImage(ShumPixelSymbols.image(named: "magnifyingglass"), for: .search, state: .normal)
            search.searchBar.setImage(ShumPixelSymbols.image(named: "xmark"), for: .clear, state: .normal)
            return search
        }()

        override func loadView() { view = UIView(); view.backgroundColor = .clear }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }
        func synchronize() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismissing else { return }
                if self.wantsSearch {
                    guard self.viewIfLoaded?.window != nil, !self.search.isActive,
                          let host = self.navigationController?.topViewController else { return }
                    self.host = host
                    host.definesPresentationContext = true
                    host.navigationItem.preferredSearchBarPlacement = .stacked
                    host.navigationItem.hidesSearchBarWhenScrolling = false
                    host.navigationItem.searchController = self.search
                    self.search.searchBar.text = self.text.wrappedValue
                    self.search.isActive = true
                } else if self.search.isActive {
                    self.isDismissing = true
                    self.search.isActive = false
                }
            }
        }
        func didPresentSearchController(_ searchController: UISearchController) {
            searchController.searchBar.becomeFirstResponder()
        }
        func updateSearchResults(for searchController: UISearchController) {
            guard !isDismissing else { return }
            let value = searchController.searchBar.text ?? ""
            if text.wrappedValue != value { text.wrappedValue = value }
        }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            isDismissing = true
            search.isActive = false
        }
        func willDismissSearchController(_ searchController: UISearchController) { isDismissing = true }
        func didDismissSearchController(_ searchController: UISearchController) {
            wantsSearch = false
            // Remove the bar only after UIKit finishes dismissal, avoiding a second collapsing animation.
            UIView.performWithoutAnimation {
                if host?.navigationItem.searchController === searchController {
                    host?.navigationItem.searchController = nil
                    host?.view.layoutIfNeeded()
                }
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                presented.wrappedValue = false
                text.wrappedValue = ""
            }
            isDismissing = false
        }
        func detach() {
            wantsSearch = false
            search.searchResultsUpdater = nil
            search.delegate = nil
            search.searchBar.delegate = nil
            search.isActive = false
            if host?.navigationItem.searchController === search { host?.navigationItem.searchController = nil }
        }
    }
}
