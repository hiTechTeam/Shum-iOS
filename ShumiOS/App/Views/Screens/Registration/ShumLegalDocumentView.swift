import SwiftUI

enum ShumLegalDocument: String, Identifiable {
    case privacy
    case terms
    case license

    var id: String { rawValue }
}

private struct ShumLegalSection: Identifiable {
    let title: String
    let paragraphs: [String]
    var bullets: [String] = []

    var id: String { title }
}

private struct ShumLegalContent {
    let title: String
    let updatedAt: String
    let introduction: String
    let sections: [ShumLegalSection]
}

struct ShumLegalDocumentView: View {
    @Environment(\.dismiss) private var dismiss

    let document: ShumLegalDocument

    private var content: ShumLegalContent {
        // Russian source strings are localization keys for every supported language.
        document.content(isRussian: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(content.updatedAt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(content.introduction)
                    .font(.body)

                ForEach(content.sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title)
                            .font(.headline)

                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.body)
                        }

                        ForEach(section.bullets, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("•")
                                Text(item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.body)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
        }
        .background(ShumThemeCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ViewThatFits(in: .horizontal) {
                    legalTitle(size: 15)
                    legalTitle(size: 13)
                    legalTitle(size: 11)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(Inc.Common.close.localized) {
                    dismiss()
                }
            }
        }
    }

    private func legalTitle(size: CGFloat) -> some View {
        Text(content.title)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private extension ShumLegalDocument {
    func content(isRussian: Bool) -> ShumLegalContent {
        switch (self, isRussian) {
        case (.license, _):
            let text = Bundle.main.url(forResource: "ShumLicense", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                ?? (isRussian ? "Не удалось загрузить текст лицензии.".localized : "The license text could not be loaded.")
            return ShumLegalContent(
                title: isRussian ? "Лицензия MIT".localized : "MIT License",
                updatedAt: isRussian ? "Лицензия программного обеспечения Shum".localized : "Shum software license",
                introduction: text,
                sections: [
                    ShumLegalSection(
                        title: isRussian ? "Сторонние компоненты".localized : "Third-party components",
                        paragraphs: [isRussian
                            ? "Полные тексты лицензий компонентов, входящих в приложение, доступны в разделе «Сторонние лицензии» на экране «О приложении».".localized
                            : "The complete license texts for components included in the app are available under Third-Party Licenses on the About screen."]
                    )
                ]
            )
        case (.privacy, true):
            return ShumLegalContent(
                title: "Политика конфиденциальности".localized,
                updatedAt: "Обновлено 13 сентября 2026 года".localized,
                introduction: "Shum — мессенджер без центрального сервера учётных записей. Для работы не нужны номер телефона, адрес электронной почты или внешний аккаунт.".localized,
                sections: [
                    ShumLegalSection(
                        title: "Какие данные использует Shum".localized,
                        paragraphs: [
                            "На устройстве хранятся имя и необязательная фотография профиля, криптографические ключи, контакты, сообщения, сведения о встречах с людьми рядом, список блокировок и настройки приложения.".localized,
                            "Когда обнаружение включено, Shum использует Bluetooth, чтобы находить другие устройства рядом. Людям рядом может передаваться подписанная карточка профиля с именем и фотографией, если она добавлена. Shum не определяет и не сохраняет точные координаты устройства.".localized,
                            "Для доставки сообщений через интернет Shum подключается к общедоступным Nostr-релеям. Релеи получают зашифрованные пакеты и технические данные, необходимые для доставки. Они не получают открытый текст сообщений, но могут видеть IP-адрес, время соединения и другие сетевые данные. Каждый релей работает по собственным правилам, которые Shum не контролирует.".localized,
                            "Камера используется только для создания фотографии профиля и сканирования QR-кодов. Выбранные фотографии обрабатываются на устройстве. Системный выбор контакта передаёт Shum только выбранные пользователем данные; приложение не загружает адресную книгу.".localized,
                            "Shum не содержит рекламы, аналитики и средств отслеживания. Разработчики Shum не продают персональные данные.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Удаление данных".localized,
                        paragraphs: [
                            "Команда «Удалить профиль и данные» удаляет профиль, ключи, контакты, историю и настройки с текущего устройства. Она не может удалить копии карточки или сообщений, которые уже находятся на устройствах собеседников либо временно сохранены сторонними Nostr-релеями.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Безопасность".localized,
                        paragraphs: [
                            "Сообщения шифруются перед отправкой. При этом ни одна программа не может гарантировать абсолютную защиту: безопасность также зависит от устройства, операционной системы, сети и выбранных релеев.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Изменения политики".localized,
                        paragraphs: [
                            "Если работа Shum с данными изменится, этот документ будет обновлён до выпуска соответствующей версии приложения.".localized
                        ]
                    )
                ]
            )

        case (.terms, true):
            return ShumLegalContent(
                title: "Правила использования".localized,
                updatedAt: "Обновлено 13 сентября 2026 года".localized,
                introduction: "Shum позволяет находить людей рядом по Bluetooth и обмениваться зашифрованными сообщениями напрямую или через общедоступные Nostr-релеи.".localized,
                sections: [
                    ShumLegalSection(
                        title: "Основные правила".localized,
                        paragraphs: [
                            "Используя Shum, вы соглашаетесь соблюдать следующие правила:".localized
                        ],
                        bullets: [
                            "не применять приложение для угроз, преследования, мошенничества и другой незаконной деятельности;".localized,
                            "не рассылать вредоносные программы, спам и содержимое, на передачу которого у вас нет права;".localized,
                            "уважать частную жизнь собеседников и не выдавать себя за другого человека;".localized,
                            "самостоятельно проверять личность собеседника, если от этого зависит безопасность общения.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Ответственность пользователя".localized,
                        paragraphs: [
                            "Вы отвечаете за имя, фотографию, сообщения и другие данные, которыми делитесь через Shum.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Работа приложения".localized,
                        paragraphs: [
                            "Shum зависит от Bluetooth, интернета, iOS, устройств других пользователей и сторонних Nostr-релеев. Поэтому доставка сообщений может задерживаться или быть недоступной. Приложение нельзя использовать как единственный способ связи в экстренной ситуации.".localized,
                            "Shum находится в разработке. Возможности, формат данных и совместимость могут меняться. Приложение предоставляется без обещания непрерывной работы или сохранности данных, поэтому важную информацию следует хранить отдельно.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Сторонние сервисы".localized,
                        paragraphs: [
                            "Общедоступные Nostr-релеи управляются третьими лицами. Их доступность, журналы соединений, сроки хранения зашифрованных пакетов и собственные правила находятся вне контроля Shum.".localized
                        ]
                    ),
                    ShumLegalSection(
                        title: "Прекращение использования".localized,
                        paragraphs: [
                            "Вы можете прекратить использование Shum и удалить локальный профиль в настройках приложения. Удаление с устройства не удаляет данные, которые ранее были переданы другим людям или сторонним релеям.".localized
                        ]
                    )
                ]
            )

        case (.privacy, false):
            return ShumLegalContent(
                title: "Privacy Policy",
                updatedAt: "Updated September 13, 2026",
                introduction: "Shum is a messenger without a central account server. It does not require a phone number, email address, or external account.",
                sections: [
                    ShumLegalSection(
                        title: "Data used by Shum",
                        paragraphs: [
                            "Your device stores your name and optional profile photo, cryptographic keys, contacts, messages, nearby encounter history, blocked profiles, and app settings.",
                            "When discovery is enabled, Shum uses Bluetooth to find nearby devices. A signed profile card containing your name and photo, if provided, may be shared with nearby people. Shum does not determine or store your precise location.",
                            "For internet delivery, Shum connects to public Nostr relays. Relays receive encrypted packets and technical data needed for delivery. They cannot read message text, but may see your IP address, connection time, and other network metadata. Each relay follows rules outside Shum's control.",
                            "The camera is used only for profile photos and QR scanning. Selected photos are processed on the device. The system contact picker gives Shum only the information you choose; the app does not upload your address book.",
                            "Shum contains no advertising, analytics, or tracking, and its developers do not sell personal data."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Deleting data",
                        paragraphs: [
                            "Delete Profile and Data removes the profile, keys, contacts, history, and settings from the current device. It cannot remove copies already held by other people or temporarily stored by third-party Nostr relays."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Security",
                        paragraphs: [
                            "Messages are encrypted before they are sent. No software can guarantee absolute protection; security also depends on the device, operating system, network, and selected relays."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Policy changes",
                        paragraphs: [
                            "If Shum's handling of data changes, this document will be updated before the related app version is released."
                        ]
                    )
                ]
            )

        case (.terms, false):
            return ShumLegalContent(
                title: "Terms of Use",
                updatedAt: "Updated September 13, 2026",
                introduction: "Shum lets people discover each other over Bluetooth and exchange encrypted messages directly or through public Nostr relays.",
                sections: [
                    ShumLegalSection(
                        title: "Basic rules",
                        paragraphs: ["By using Shum, you agree to:"],
                        bullets: [
                            "not use the app for threats, harassment, fraud, or other illegal activity;",
                            "not distribute malware, spam, or content you do not have the right to share;",
                            "respect other people's privacy and not impersonate anyone;",
                            "verify a person's identity yourself when the safety of a conversation depends on it."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Your responsibility",
                        paragraphs: [
                            "You are responsible for the name, photo, messages, and other information you share through Shum."
                        ]
                    ),
                    ShumLegalSection(
                        title: "How the app works",
                        paragraphs: [
                            "Shum depends on Bluetooth, internet access, iOS, other users' devices, and third-party Nostr relays. Message delivery may be delayed or unavailable. Do not rely on the app as your only means of communication in an emergency.",
                            "Shum is under development. Features, data formats, and compatibility may change. Continuous operation and preservation of data are not guaranteed, so keep important information elsewhere."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Third-party services",
                        paragraphs: [
                            "Public Nostr relays are operated by third parties. Their availability, connection logs, encrypted packet retention, and policies are outside Shum's control."
                        ]
                    ),
                    ShumLegalSection(
                        title: "Stopping use",
                        paragraphs: [
                            "You may stop using Shum and delete your local profile in the app settings. Deleting data from your device does not remove information previously sent to other people or third-party relays."
                        ]
                    )
                ]
            )
        }
    }
}
