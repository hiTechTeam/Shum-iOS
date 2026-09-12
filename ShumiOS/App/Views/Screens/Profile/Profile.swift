import SwiftUI

struct Profile: View {
    
    @ObservedObject var authVM: LocalProfileViewModel
    @StateObject private var photoViewModel = ProfilePhotoViewModel()
    
    private let profileInc: String = Inc.Tabs.profile.localized
    private let profileTabInc: String = Inc.Tabs.me.localized
    
    var body: some View {
        NavigationStack {
            ProfileDataView(
                authCodeViewModel: authVM,
                photoViewModel: photoViewModel
            )
                .navigationTitle(profileInc)
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            authVM.restoreLocalProfile()
        }
        .tabItem {
            Label(profileTabInc, shumSymbol: IncLogos.personFillViewwfinder)
        }
        .tag(SelectedTab.profile)
    }
}
