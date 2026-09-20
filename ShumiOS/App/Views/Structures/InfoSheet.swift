import SwiftUI

struct InfoSheetView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShumLogoMark().frame(width: 70, height: 70)
                Text("Shum").font(.largeTitle.bold())
                Text("Общение рядом и на расстоянии").font(.title3)
                Text("Находите людей рядом через Bluetooth или добавляйте по QR-коду. Постоянный контакт позволяет продолжить переписку через интернет, когда вы далеко друг от друга.")
                Text("Сообщения защищены сквозным шифрованием. Bluetooth и Nostr передают зашифрованные данные; история хранится зашифрованной на этом iPhone. Ключи остаются на устройстве.")
                Text("Когда приложение закрыто, iOS может приостановить соединение. Откройте Shum для получения ожидающих сообщений. Очередь хранит неотправленные сообщения до 24 часов.").foregroundStyle(.secondary)
                Text("Экспериментальная версия").font(.headline)
                Text("Пока доступны текстовые сообщения. Есть очередь отправки, подтверждения доставки и прочтения. Звонки и вложения ещё не подключены.").foregroundStyle(.secondary)
                Text("Транспорт и шифрование: BitChat / Shum, Unlicense.").font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.navigationTitle("О приложении")
    }
}
