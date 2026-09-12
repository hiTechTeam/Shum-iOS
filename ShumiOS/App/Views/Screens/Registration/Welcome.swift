import SwiftUI

struct Welcome: View {
    @EnvironmentObject private var coordinator: AppCoordinator
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
                NavigationLink {
                    LocalCardRegistration(photoViewModel: coordinator.profilePhotoViewModel)
                } label: {
                    Text("Создать профиль").font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding(17).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Профиль создаётся на этом iPhone. Номер телефона и внешний аккаунт не нужны.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.bottom, 18)
            }.padding(.horizontal, 28).background(Color("ls-Background").ignoresSafeArea())
        }.tint(.accentColor)
    }
}
