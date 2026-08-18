import SwiftUI

struct InfoSheetView: View {
    private let sectionSpacing: CGFloat = 16

    private let githubURL = URL(
        string: "https://github.com/hiTechTeam/Telescan-info"
    )!
    private let privacyPolicyURL = URL(string: Links.privacyPolicy)!
    private let termsOfServiceURL = URL(string: Links.termsOfService)!

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? Inc.Info.currentVersion
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func sectionDescription(_ description: String) -> some View {
        Text(description)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private var storySection: some View {
        Section(
            header: sectionHeader(Inc.Info.whyTelescan.localized)
        ) {
            sectionDescription(Inc.Info.story.localized)
        }
    }

    private var howItWorksSection: some View {
        Section(
            header: sectionHeader(Inc.Info.howItWorks.localized)
        ) {
            sectionDescription(Inc.Info.howItWorksDescription.localized)
        }
    }

    private var legalSection: some View {
        Section(
            header: sectionHeader(Inc.Info.rulesAndPrivacy.localized)
        ) {
            Link(
                Inc.Onboarding.termsOfService.localized,
                destination: termsOfServiceURL
            )

            Link(
                Inc.Onboarding.privacyPolicy.localized,
                destination: privacyPolicyURL
            )
        }
    }

    private var appDetailsSection: some View {
        Section(
            header: sectionHeader(Inc.Info.aboutApp.localized),
            footer: Text(Inc.Info.proprietaryLicense.localized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .center)
                .textCase(nil)
                .padding(.top, 8)
        ) {
            HStack {
                Text(Inc.Info.version.localized)

                Spacer()

                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            Link(destination: githubURL) {
                HStack {
                    Text(Inc.Info.publicProject.localized)
                }
            }
        }
    }

    private var listContent: some View {
        List {
            storySection
            howItWorksSection
            legalSection
            appDetailsSection
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(sectionSpacing)
        .contentMargins(.vertical, 16, for: .scrollContent)
    }

    var body: some View {
        listContent
    }
}
