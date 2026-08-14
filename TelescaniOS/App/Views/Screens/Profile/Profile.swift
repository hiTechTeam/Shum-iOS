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
            authVM.restoreLocalProfile()
        }
        .tabItem { Label(profileInc, systemImage: IncLogos.personFillViewwfinder) }
        .tag(SelectedTab.profile)
    }
}
