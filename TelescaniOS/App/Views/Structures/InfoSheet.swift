import SwiftUI

struct InfoSheetView: View {
    
    // MARK: - Constants
    private let boltFill = "bolt.fill"
    private let lockFill = "lock.fill"
    private let netWork = "network"
    
    private let boxWidth: CGFloat = 360
    private let boxHeight: CGFloat = 52
    private let cornerRadius: CGFloat = 13
    private let blockSpacing: CGFloat = 16
    private let verticalContentMargin: CGFloat = 24
    
    private let githubURL = URL(string: "https://github.com/hiTechTeam/Telescan-info")!
    private let githubURLString = "github.com/hiTechTeam/Telescan-info"
    private let privacyPolicyURL = URL(string: Links.privacyPolicy)!
    private let termsOfServiceURL = URL(string: Links.termsOfService)!
    
    // MARK: - Components
    private var headerSection: some View {
        VStack(spacing: blockSpacing) {
            VStack(spacing: blockSpacing) {
                Text(Inc.Info.Telescan)
                    .font(.system(size: 24, weight: .medium))
                    .multilineTextAlignment(.center)
                
                Text(Inc.Info.mainDescription.localized)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: blockSpacing) {
                InfoItem(
                    icon: boltFill,
                    title: Inc.Info.instantExchangeTitle.localized,
                    description: Inc.Info.instantExchangeDesc.localized
                )
                
                Divider()
                
                InfoItem(
                    icon: lockFill,
                    title: Inc.Info.dataProtectionTitle.localized,
                    description: Inc.Info.dataProtectionDesc.localized
                )
                
                Divider()
                
                InfoItem(
                    icon: netWork,
                    title: Inc.Info.idealForEventsTitle.localized,
                    description: Inc.Info.idealForEventsDesc.localized
                )
            }
        }
    }
    
    private var projectInfoSection: some View {
        VStack(spacing: blockSpacing) {
            HStack(spacing: 12) {
                Image.tsIconGraySmall
                    .resizable()
                    .frame(width: 24, height: 25)
                
                Text(Inc.Info.version.localized + Inc.Info.currentVersion)
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: boxWidth, alignment: .center)
            
            Divider()
            
            Link(githubURLString, destination: githubURL)
                .font(.system(size: 12, weight: .medium))
                .frame(width: boxWidth, height: boxHeight, alignment: .center)
        }
    }

    private var legalSection: some View {
        Section(Inc.Info.rulesAndPrivacy.localized) {
            Link(destination: termsOfServiceURL) {
                Label(
                    Inc.Onboarding.termsOfService.localized,
                    systemImage: "doc.text"
                )
            }

            Link(destination: privacyPolicyURL) {
                Label(
                    Inc.Onboarding.privacyPolicy.localized,
                    systemImage: "hand.raised"
                )
            }
        }
    }
    
    private var listContent: some View {
        List {
            Section { headerSection }

            legalSection
            
            Section(
                header: Text(Inc.Info.projectAccessText.localized)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.gray)
                    .textCase(nil),
                footer: Text(Inc.Info.proprietaryLicense.localized)
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(.gray)
                    .frame(width: boxWidth, alignment: .center)
            ) {
                projectInfoSection
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(blockSpacing)
        .contentMargins(
            .vertical,
            verticalContentMargin,
            for: .scrollContent
        )
    }
    
    // MARK: - Body
    var body: some View {
        listContent
    }
}

struct InfoItem: View {
    
    var icon: String
    var title: String
    var description: String
    
    private var content: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                
                Text(description)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - Body
    var body: some View {
        content
    }
}
