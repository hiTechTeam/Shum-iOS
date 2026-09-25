import SwiftUI

private struct ShumBundledLicenseResource: Identifiable {
    let title: String
    let name: String

    var id: String { name }

    var text: String {
        Bundle.main.url(forResource: name, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "thirdPartyLicenseUnavailable".localized
    }
}

private struct ShumThirdPartyComponent: Identifiable {
    let name: String
    let version: String
    let license: String
    let sourceURL: URL
    let resources: [ShumBundledLicenseResource]

    var id: String { name }

    static let bundled: [Self] = [
        Self(
            name: "BitChat Bluetooth, BitFoundation and BitLogger",
            version: "Revision 9b84b361",
            license: "The Unlicense",
            sourceURL: URL(string: "https://github.com/permissionlesstech/bitchat")!,
            resources: [
                ShumBundledLicenseResource(
                    title: "The Unlicense",
                    name: "ThirdPartyBitchatUnlicense"
                )
            ]
        ),
        Self(
            name: "SwiftLog",
            version: "1.8.0",
            license: "Apache License 2.0",
            sourceURL: URL(string: "https://github.com/apple/swift-log")!,
            resources: [
                ShumBundledLicenseResource(
                    title: "Apache License 2.0",
                    name: "ThirdPartySwiftLogApache2"
                ),
                ShumBundledLicenseResource(
                    title: "NOTICE",
                    name: "ThirdPartySwiftLogNotice"
                )
            ]
        ),
        Self(
            name: "swift-secp256k1",
            version: "0.21.1",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/21-DOT-DEV/swift-secp256k1")!,
            resources: [
                ShumBundledLicenseResource(
                    title: "MIT License",
                    name: "ThirdPartySwiftSecp256k1MIT"
                )
            ]
        ),
        Self(
            name: "libsecp256k1",
            version: "Revision 70f149b9",
            license: "MIT License",
            sourceURL: URL(string: "https://github.com/bitcoin-core/secp256k1")!,
            resources: [
                ShumBundledLicenseResource(
                    title: "MIT License",
                    name: "ThirdPartyLibSecp256k1MIT"
                )
            ]
        )
    ]
}

struct ShumThirdPartyLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text("thirdPartyLicensesIntro".localized)
                    .font(.body)
            }

            Section {
                ForEach(ShumThirdPartyComponent.bundled) { component in
                    NavigationLink {
                        ShumThirdPartyLicenseTextView(
                            component: component
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(component.name)
                                .foregroundStyle(.primary)
                            Text("\(component.version) · \(component.license)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("thirdPartyLicensesTitle".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(Inc.Common.close.localized) { dismiss() }
            }
        }
    }
}

private struct ShumThirdPartyLicenseTextView: View {
    let component: ShumThirdPartyComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(component.name)
                        .font(.title3.weight(.semibold))
                    Text("\(component.version) · \(component.license)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(
                        "thirdPartyLicensesSourceCode".localized,
                        destination: component.sourceURL
                    )
                    .font(.footnote)
                }

                ForEach(component.resources) { resource in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(resource.title)
                            .font(.headline)
                        Text(resource.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
