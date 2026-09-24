import SwiftUI

struct InfoSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var legalDocument: ShumLegalDocument?

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Inc.Info.version.localized + " " + version + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        ShumLogoMark().frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shum").font(.largeTitle.bold())
                            Text(version).font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("about_tagline".localized).font(.title3.weight(.semibold))
                        Text("about_summary".localized)
                        Text("about_connection".localized)
                        Text("about_protection".localized)
                    }
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ProfileMenuButton(position: .top, action: { legalDocument = .privacy }) {
                            row(Inc.Onboarding.privacyPolicy.localized, symbol: "hand.raised")
                        }
                        .accessibilityIdentifier("shum.about.privacy")
                        Divider().padding(.leading, 52)
                        ProfileMenuButton(position: .middle, action: { legalDocument = .terms }) {
                            row(Inc.Onboarding.termsOfService.localized, symbol: "doc.text")
                        }
                        .accessibilityIdentifier("shum.about.terms")
                        Divider().padding(.leading, 52)
                        ProfileMenuButton(position: .bottom, action: {
                            if let url = URL(string: Links.supportIssues) { openURL(url) }
                        }) {
                            row("about_support".localized, symbol: "lifepreserver", external: true)
                        }
                        .accessibilityIdentifier("shum.about.support")
                        .accessibilityHint("about_support_hint".localized)
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("about_delivery_note".localized)
                        Text("about_credits".localized)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle(Inc.Info.aboutApp.localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) { dismiss() }
                }
            }
            .sheet(item: $legalDocument) { document in
                NavigationStack {
                    ShumLegalDocumentView(document: document)
                }
            }
        }
    }

    private func row(_ title: String, symbol: String, external: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24)
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: external ? "arrow.up.right" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }
}
