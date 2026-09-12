import SwiftUI

struct People: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel
    @ObservedObject var authVM: LocalProfileViewModel
    
    private let peopNearleInc: String = Inc.Common.nearby.localized
    private let peopleInc: String = Inc.Common.nearby.localized
    
    var body: some View {
        NavigationStack {
            PeopleView()
                .navigationTitle(peopNearleInc)
                .navigationBarTitleDisplayMode(.large)
        }
        .tabItem {
            Label(
                peopleInc,
                systemImage: coordinator.isScaning
                    ? IncLogos.shareplay
                    : "shareplay.slash"
            )
        }
        .tag(SelectedTab.near)
        .badge(peopleViewModel.visibleUsers.count)
    }
}
