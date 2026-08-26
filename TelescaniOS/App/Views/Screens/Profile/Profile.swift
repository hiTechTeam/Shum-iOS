import SwiftUI

struct Profile: View {
    
    @ObservedObject var authVM: CodeViewModel
    @StateObject private var photoViewModel = ProfilePhotoViewModel()
    
    private let profileInc: String = Inc.Tabs.profile.localized
    
    var body: some View {
        NavigationStack {
            ProfileDataView(
                authCodeViewModel: authVM,
                photoViewModel: photoViewModel
            )
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
