import SwiftUI
import UIKit

struct HowShumWorksView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var page = 0
    @State private var showRegistration = false

    private let pages: [ShumOnboardingContent] = [
        ShumOnboardingContent(
            illustration: .nearby,
            title: "Люди рядом".localized,
            description: "Shum находит людей поблизости по Bluetooth. Можно познакомиться и начать общение напрямую между устройствами.".localized
        ),
        ShumOnboardingContent(
            illustration: .mesh,
            title: "Связь без интернета".localized,
            description: "Если рядом есть другие пользователи Shum, сообщения проходят по mesh-сети от устройства к устройству. Интернет не нужен.".localized
        ),
        ShumOnboardingContent(
            illustration: .courier,
            title: "Сообщение найдёт путь".localized,
            description: "Устройство рядом может временно сохранить зашифрованное сообщение и передать его дальше позже. Содержимое видите только вы и получатель.".localized
        ),
        ShumOnboardingContent(
            illustration: .network,
            title: "Общайтесь без единого центра".localized,
            description: "У Shum нет единого сервера, который управляет общением. Сообщения передаются напрямую и через распределённую сеть Nostr.".localized
        ),
        ShumOnboardingContent(
            illustration: .identity,
            title: "Ваш профиль принадлежит вам".localized,
            description: "Профиль защищён криптографическими ключами на устройстве. Только вы управляете своей личностью и резервной копией.".localized
        )
    ]

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, content in
                ShumOnboardingPage(
                    illustration: content.illustration,
                    title: content.title,
                    description: content.description,
                    pageIndex: index,
                    pageCount: pages.count,
                    buttonTitle: index == pages.indices.last ? "Создать профиль".localized : "Продолжить".localized
                ) {
                    continueOnboarding(from: index)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(ShumThemeCanvas().ignoresSafeArea())
        .toolbarBackground(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.25), value: page)
        .navigationDestination(isPresented: $showRegistration) {
            RegistrationSecurityCreationView()
        }
    }

    private func continueOnboarding(from index: Int) {
        guard index == page else { return }
        if page < pages.count - 1 {
            withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
        } else {
            showRegistration = true
        }
    }
}
private struct ShumOnboardingContent {
    let illustration: ShumOnboardingPixelIllustration.Kind
    let title: String
    let description: String
}
private struct ShumOnboardingPage: View {
    let illustration: ShumOnboardingPixelIllustration.Kind
    let title: String
    let description: String
    let pageIndex: Int
    let pageCount: Int
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ShumOnboardingPixelIllustration(kind: illustration)
                .foregroundStyle(Color.accentColor)
                .frame(width: 112, height: 92)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 34)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 340)

            Spacer()

            HStack(spacing: 9) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.38))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String.localizedFormat("Экран %@ из %@".localized, pageIndex + 1, pageCount))
            .padding(.bottom, 30)

            RegistrationPrimaryButton(
                title: buttonTitle,
                isEnabled: true,
                accentColor: Color.accentColor,
                action: action
            )
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
