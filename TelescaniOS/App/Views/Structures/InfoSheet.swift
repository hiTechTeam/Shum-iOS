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

    private var heroSection: some View {
        VStack(spacing: 10) {
            Image.tsIcon66
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            Text(Inc.Info.Telescan)
                .font(.system(size: 24, weight: .semibold))

            Text(Inc.Info.mainDescription.localized)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var storySection: some View {
        Section(
            header: sectionHeader(Inc.Info.whyTelescan.localized)
        ) {
            Text(Inc.Info.story.localized)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        }
    }

    private var howItWorksSection: some View {
        Section(
            header: sectionHeader(Inc.Info.howItWorks.localized)
        ) {
            InfoItem(
                icon: "antenna.radiowaves.left.and.right",
                title: Inc.Info.nearbyDiscoveryTitle.localized,
                description: Inc.Info.nearbyDiscoveryDescription.localized
            )

            InfoItem(
                icon: "person.crop.circle",
                title: Inc.Info.profileDisplayTitle.localized,
                description: Inc.Info.profileDisplayDescription.localized
            )

            InfoItem(
                icon: "paperplane.fill",
                title: Inc.Info.telegramContactTitle.localized,
                description: Inc.Info.telegramContactDescription.localized
            )
        }
    }

    private var legalSection: some View {
        Section(
            header: sectionHeader(Inc.Info.rulesAndPrivacy.localized)
        ) {
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

    private var appDetailsSection: some View {
        Section(
            header: sectionHeader(Inc.Info.aboutApp.localized),
            footer: Text(Inc.Info.proprietaryLicense.localized)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .textCase(nil)
                .padding(.top, 8)
        ) {
            HStack(spacing: 14) {
                Image(systemName: "app.badge")
                    .foregroundStyle(.blue)
                    .frame(width: 24)

                Text(Inc.Info.version.localized)

                Spacer()

                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            Link(destination: githubURL) {
                HStack(spacing: 14) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.blue)
                        .frame(width: 24)

                    Text(Inc.Info.publicProject.localized)

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var listContent: some View {
        List {
            Section { heroSection }
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
        NavigationStack {
            listContent
                .navigationTitle(Inc.Info.aboutTelescan.localized)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct InfoItem: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
