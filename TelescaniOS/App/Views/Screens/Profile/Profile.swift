import SwiftUI

struct Profile: View {
    
    @ObservedObject var authVM: CodeViewModel
    
    private let profileInc: String = Inc.Tabs.profile.localized
    
    var body: some View {
        NavigationStack {
            ProfileDataView(authCodeViewModel: authVM)
                .navigationTitle(authVM.tgName ?? profileInc)
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            authVM.restoreLocalProfile()
        }
        .tabItem { Label(profileInc, systemImage: IncLogos.personFillViewwfinder) }
        .tag(SelectedTab.profile)
    }
}
