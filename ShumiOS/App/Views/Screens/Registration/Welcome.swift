import SwiftUI
import UniformTypeIdentifiers

struct Welcome: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var legalDocument: ShumLegalDocument?
    @State private var isImportingBackup = false
    @State private var importedBackup: Data?
    @State private var showRestore = false
    @State private var showSecuritySetup = false
    @State private var importError: String?

    private let privacyPolicyURL = URL(string: "shum-legal://privacy")!
    private let termsOfServiceURL = URL(string: "shum-legal://terms")!

    private var legalText: AttributedString {
        let privacyTitle = Inc.Onboarding.privacyPolicy.localized
        let termsTitle = Inc.Onboarding.termsOfService.localized
        let content = String(
            format: Inc.Onboarding.legalAgreement.localized,
            privacyTitle,
            termsTitle
        )
        var text = AttributedString(content)
        text.foregroundColor = .secondary
        text.font = .system(size: 12, weight: .regular)

        if let range = text.range(of: privacyTitle) {
            text[range].link = privacyPolicyURL
            text[range].foregroundColor = .accentColor
        }
        if let range = text.range(of: termsTitle) {
            text[range].link = termsOfServiceURL
            text[range].foregroundColor = .accentColor
        }
        return text
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image("ShumLogo").resizable().scaledToFit().frame(width: 100, height: 100)
                Text("Shum").font(.system(size: 46, weight: .bold))
                Text("Разговор начинается рядом").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text("Находите людей поблизости и общайтесь по Bluetooth. Даже без интернета.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                Text(legalText)
                    .multilineTextAlignment(.center)
                    .tint(.accentColor)
                NavigationLink {
                    HowShumWorksView()
                } label: {
                    Text(Inc.Onboarding.start.localized)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)

                Button("Восстановить из резервной копии") {
                    isImportingBackup = true
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 36)

                Text("Профиль создаётся на этом устройстве. Номер телефона и внешний аккаунт не нужны.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 18)
            }.padding(.horizontal, 28).background(Color("ls-Background").ignoresSafeArea())
                .navigationDestination(isPresented: $showSecuritySetup) {
                    RegistrationSecurityReadyView()
                }
        }
        .tint(.accentColor)
        .environment(\.openURL, OpenURLAction { url in
            switch (url.host ?? url.path).lowercased() {
            case "privacy":
                legalDocument = .privacy
                return .handled
            case "terms":
                legalDocument = .terms
                return .handled
            default:
                return .discarded
            }
        })
        .sheet(item: $legalDocument) { document in
            NavigationStack {
                ShumLegalDocumentView(document: document)
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.shumBackup, .data]
        ) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 131 * 1024 * 1024 else {
                    throw ShumBackupError.backupTooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                _ = try ShumBackupService.shared.metadata(for: data)
                importedBackup = data
                showRestore = true
            } catch {
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showRestore, onDismiss: {
            importedBackup = nil
        }) {
            if let importedBackup {
                ShumBackupRestoreView(data: importedBackup) {
                    showSecuritySetup = true
                }
                .environmentObject(coordinator)
            }
        }
        .alert("Не удалось открыть копию", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text(importError ?? "")
        }
        .task {
            if coordinator.needsSecuritySetup {
                showSecuritySetup = true
            }
        }
    }
}
