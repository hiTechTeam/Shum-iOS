import SwiftUI

struct InfoSheetView: View {
    @Environment(\.openURL) private var openURL
    @State private var showDeveloperLinks = false

    private let sectionSpacing: CGFloat = 16

    private let githubURL = URL(
        string: "https://github.com/hiTechTeam/Telescan-info"
    )!
    private let privacyPolicyURL = URL(string: Links.privacyPolicy)!
    private let termsOfServiceURL = URL(string: Links.termsOfService)!
    private let developerActionURL = URL(string: "telescan://developer")!
    private let developerGitHubURL = URL(string: "https://github.com/r66cha")!
    private let developerTelegramURL = URL(string: "https://t.me/r_chukavin")!
    private let supportEmailURL = URL(string: "mailto:admin@tgtelescan.ru")!

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? Inc.Info.currentVersion
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .textCase(nil)
    }

    private func sectionDescription(_ description: String) -> some View {
        Text(description)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private var copyrightNotice: AttributedString {
        var notice = AttributedString(Inc.Info.proprietaryLicense.localized)
        if let name = notice.range(of: "Ruslan Chukavin") {
            notice[name].foregroundColor = .blue
            notice[name].link = developerActionURL
        }
        return notice
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
            footer: Text(copyrightNotice)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .tint(.blue)
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

            Link(destination: supportEmailURL) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Inc.Info.questionsAndSuggestions.localized)

                    Text("admin@tgtelescan.ru")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard url == developerActionURL else {
                        return .systemAction
                    }
                    showDeveloperLinks = true
                    return .handled
                }
            )
            .alert(
                Inc.Profile.developerLinksTitle.localized,
                isPresented: $showDeveloperLinks
            ) {
                Button("GitHub") {
                    openURL(developerGitHubURL)
                }
                Button(Inc.Profile.telegramChannel.localized) {
                    openURL(developerTelegramURL)
                }
                Button(Inc.Common.cancel.localized, role: .cancel) { }
            } message: {
                Text(Inc.Profile.developerLinksMessage.localized)
            }
    }
}
