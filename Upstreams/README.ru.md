# Внешние источники

[English](README.md) · Русский

Ревизии закреплены в [versions.json](versions.json). Изменения проходят проверку до включения в приложение.

## Источники

- [Bitchat](https://github.com/permissionlesstech/bitchat), Unlicense: Bluetooth-сетка, Noise, доставка через курьеров и утилиты протокола. Код для проверки размещается в `.upstreams/bitchat`.
- [Telegram iOS](https://github.com/TelegramMessenger/Telegram-iOS), GPL-2.0-or-later: только ориентир для взаимодействий и компонентов. Его код не копируется и не собирается в Shum; взаимодействия реализуются независимо.

Bluetooth подключён через `Transport` в [Transport.swift](../ShumiOS/Vendor/Bluetooth/Services/Transport.swift). `BitchatTransportFactory` создаёт рабочий BLE-движок. Файлы внешнего проекта не заменяют текущий транспорт автоматически.

## Обновление

1. `Scripts/upstreams/status.sh`: сравнить закреплённые ревизии с внешними.
2. `Scripts/upstreams/fetch.sh all`: получить закреплённые коммиты.
3. `Scripts/upstreams/materialize-bitchat.sh`: подготовить код для проверки.
4. Перенести проверенные изменения через границу Transport.
5. Проверить сборку, сообщения, поиск, курьерскую доставку и миграцию перед обновлением versions.json.

Запускайте скрипты из корня репозитория.
