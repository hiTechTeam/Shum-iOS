import SwiftUI

struct Profile: View {
    
    @ObservedObject var authVM: CodeViewModel
    @State private var showInfoSheet = false
    
    private let profileInc: String = Inc.Tabs.profile.localized
    
    var body: some View {
        NavigationStack {
            ProfileDataView(authCodeViewModel: authVM)
                .navigationTitle(authVM.tgName ?? profileInc)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(
                            action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                showInfoSheet = true
                            },
                            label: {
                                Image.infoImage
                                    .foregroundColor(.gray)
                            }
                        )
                    }
                }
                .sheet(isPresented: $showInfoSheet) {
                    InfoSheetView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
        .onAppear {
            if let tgID = UserDefaults.standard.object(
                forKey: Keys.tgIdKey.rawValue
            ) as? Int {
                authVM.tgID = tgID
                authVM.isUsernameConfirmed = true
            }

            if let tgName = UserDefaults.standard.string(forKey: Keys.tgNameKey.rawValue) {
                authVM.tgName = tgName
            }
            
            if let code = UserDefaults.standard.string(forKey: Keys.cleanCodeKey.rawValue) {
                authVM.code = code
            }
            
            if let username = UserDefaults.standard.string(forKey: Keys.usernameKey.rawValue) {
                authVM.tgUsername = username
            }

            if let photoURL = UserDefaults.standard.string(
                forKey: Keys.photoS3URLKey.rawValue
            ) {
                authVM.photoS3URL = photoURL
            }
        }
        .tabItem { Label(profileInc, systemImage: IncLogos.personFillViewwfinder) }
        .tag(SelectedTab.profile)
    }
}
