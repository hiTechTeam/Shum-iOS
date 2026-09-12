import SwiftUI

struct InfoSheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image("ShumLogo").resizable().scaledToFit().frame(width: 70, height: 70)
                Text("Shum").font(.largeTitle.bold())
                Text("Общение рядом без интернета").font(.title3)
                Text("Эта версия использует Bluetooth для поиска людей и личной переписки. Откройте Shum на двух iPhone поблизости и включите видимость.")
                Text("Профиль и история чатов хранятся на вашем устройстве. Сообщения передаются через зашифрованные сеансы Bluetooth. Доступность доставки зависит от расстояния и ограничений iOS в фоне.")
                Text("Экспериментальная версия").font(.headline)
                Text("Пока доступны текстовые сообщения. Интернет-доставка, звонки и обмен файлами ещё не подключены.").foregroundStyle(.secondary)
                Text("Bluetooth-компоненты: BitChat / Spotchat, Unlicense.").font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.navigationTitle("О приложении")
    }
}
