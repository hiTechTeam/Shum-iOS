<p align="center">
  <img src="docs/screenshots/icon.png" width="96" alt="Shum">
</p>

<h1 align="center">Shum для iPhone</h1>

<p align="center">
  Общайтесь с людьми рядом по Bluetooth и на расстоянии через независимые релеи Nostr.<br>
  Без номера телефона и почты.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6816236820"><img src="https://img.shields.io/itunes/v/6816236820?label=App%20Store&logo=apple&color=2f9e4a" alt="Версия в App Store"></a>
  <img src="https://img.shields.io/badge/iOS-16%2B-111111?logo=apple" alt="iOS 16+">
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/license-MIT-111111" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · Русский
</p>

<p align="center">
  <img src="docs/screenshots/ru-1.jpg" width="24%" alt="Чат без интернета">
  <img src="docs/screenshots/ru-2.jpg" width="24%" alt="Чаты рядом и далеко">
  <img src="docs/screenshots/ru-3.jpg" width="24%" alt="Сквозное шифрование">
  <img src="docs/screenshots/ru-4.jpg" width="24%" alt="Кого вы встретили">
</p>

## Скачать

[Shum в App Store](https://apps.apple.com/app/id6816236820), для iPhone с iOS 16 и новее. Бейдж выше показывает версию, которая сейчас в продаже.

Shum работает и на компьютере, и в браузере: [приложение для компьютера и Shum Web](https://github.com/hiTechTeam/Shum-App), [клиент для терминала](https://github.com/hiTechTeam/Shum-CLI). Один профиль работает везде.

## Возможности

- **Без интернета.** Текстовые сообщения идут по Bluetooth между телефонами рядом.
- **Рядом и далеко.** С интернетом сообщения идут через независимые релеи Nostr.
- **Сквозное шифрование.** Ключи хранятся на ваших устройствах, история зашифрована на устройстве.
- **Встречи.** Люди, с которыми вы пересеклись за последние 24 часа, их можно сразу добавить.
- **Без номера телефона.** Достаточно имени. Людей можно добавить по QR-карточке, ссылке или сетевому ID.
- **Ваши устройства.** Привяжите к тому же профилю Shum на компьютере, в браузере или в терминале.
- **Резервные копии.** Сохраните профиль в файл с паролем или восстановите его как ещё один профиль.
- **Приватность.** Код приложения, Face ID или Touch ID, скрытые чаты в переключателе приложений.
- **Пиксельные аватары**, созданные на устройстве, или ваше фото.

Сохранение контакта и принятие приглашения в чат происходят отдельно. Сервер разработчиков отправляет push-уведомления, не получая текст сообщений.

## Проект

Откройте `ShumiOS.xcodeproj` в Xcode. Логика сообщений живёт в общем ядре на Rust, [Shum-Core](https://github.com/hiTechTeam/Shum-Core); приложение её показывает. Зависимости и ревизии внешних проектов записаны в репозитории. Сторонний код сохраняет свои лицензии.

[Протокол](https://github.com/hiTechTeam/Shum-Protocol) · [Ядро Rust](https://github.com/hiTechTeam/Shum-Core) · [Компьютер и веб](https://github.com/hiTechTeam/Shum-App) · [CLI](https://github.com/hiTechTeam/Shum-CLI) · [Внешние источники](Upstreams/README.ru.md)

## Поддержка и правила

[getshum.tech](https://getshum.tech) · [Issues](https://github.com/hiTechTeam/Shum-iOS/issues) · [Конфиденциальность](PRIVACY.md) · [Правила использования](TERMS.md)

## Лицензия

[MIT](LICENSE.md), © 2021–2026 Руслан Чукавин. [Лицензии сторонних компонентов](Upstreams/README.ru.md), включая [Unlicense для Bluetooth](BLUETOOTH-LICENSE), сохраняются.
