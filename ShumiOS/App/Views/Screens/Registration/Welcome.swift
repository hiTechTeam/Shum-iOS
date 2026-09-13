import SwiftUI

struct Welcome: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    private var privacyPolicyURL: URL { URL(string: Links.privacyPolicy)! }
    private var termsOfServiceURL: URL { URL(string: Links.termsOfService)! }

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
                    Text("Создать профиль")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                Text("Профиль создаётся на этом устройстве. Номер телефона и внешний аккаунт не нужны.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 18)
            }.padding(.horizontal, 28).background(Color("ls-Background").ignoresSafeArea())
        }.tint(.accentColor)
    }
}
