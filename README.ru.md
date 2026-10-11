<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="">
</p>

<h1 align="center">Perekey</h1>

<p align="center">
  Бесплатный переключатель раскладки для macOS с открытым кодом.<br>
  Набрали <code>ghbdtn</code> вместо <code>привет</code>? Perekey исправит сам или по нажатию Option.
</p>

<p align="center">
  <a href="https://github.com/tlgnkl/perekey/releases/latest/download/Perekey.dmg"><img src="https://img.shields.io/badge/%D0%A1%D0%BA%D0%B0%D1%87%D0%B0%D1%82%D1%8C_%D0%B4%D0%BB%D1%8F_macOS-5E5CE6?style=for-the-badge&logo=apple&logoColor=white" alt="Скачать для macOS"></a>
</p>

<p align="center">
  <a href="https://github.com/tlgnkl/perekey/releases/latest"><img src="https://img.shields.io/github/v/release/tlgnkl/perekey?label=%D0%B2%D0%B5%D1%80%D1%81%D0%B8%D1%8F&color=5E5CE6" alt="Последняя версия"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-555" alt="macOS 14 и новее">
  <img src="https://img.shields.io/badge/Apple_Silicon_%2B_Intel-555" alt="Apple Silicon и Intel">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tlgnkl/perekey?color=555" alt="GPL-3.0"></a>
</p>

<p align="center">
  <a href="https://tlgnkl.github.io/perekey/">Сайт</a> ·
  <a href="CHANGELOG.md">Что нового</a> ·
  <a href="https://github.com/tlgnkl/perekey/releases">Все выпуски</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hint-corrected-dark.png">
    <img src="docs/images/hint-corrected-light.png" width="384" alt="Подсказка у курсора: ghbdtn → привет, кнопка «Отменить»">
  </picture>
</p>

## Установка

1. [Скачайте `Perekey.dmg`](https://github.com/tlgnkl/perekey/releases/latest/download/Perekey.dmg)
   из последнего выпуска.
2. Откройте образ и перетащите Perekey в «Программы».
3. Запустите Perekey из «Программ».
4. Разрешите «Универсальный доступ» и «Мониторинг ввода», когда Perekey
   попросит. Без них он не видит нажатия и не может заменить слово.

Нужна macOS 14 или новее, Apple Silicon или Intel.

Или через Homebrew:

```sh
brew install --cask tlgnkl/tap/perekey
```

> [!IMPORTANT]
> Сборки пока без подписи Apple, поэтому macOS не даст запустить Perekey
> с первого раза.
> - **macOS 15 и новее:** откройте Perekey, закройте предупреждение, затем
>   откройте «Системные настройки» → «Конфиденциальность и безопасность»
>   и нажмите **«Всё равно открыть»**.
> - **macOS 14:** в «Программах» нажмите на Perekey с Control, выберите
>   **«Открыть»**, затем ещё раз **«Открыть»**.

**Обновления.** Perekey раз в день проверяет новую версию и спрашивает перед
установкой. Изменения каждого выпуска — в [CHANGELOG.md](CHANGELOG.md) и на
[странице выпусков](https://github.com/tlgnkl/perekey/releases). Рядом с каждым
образом лежит файл `.sha256`: `shasum -a 256 -c Perekey-<версия>.dmg.sha256`.

## Что умеет

- **Перенабор по сочетанию.** Option (или любое сочетание) перенабирает
  последнее слово или выделение в другой раскладке. Повторное нажатие
  возвращает как было.
- **Автопереключение.** Языковая модель внутри приложения решает в конце
  каждого слова. Один Backspace сразу после замены отменяет её, и Perekey
  запоминает слово: подсказка у курсора говорит об этом и предлагает «Забыть».
- **Опечатки.** Опечатки в одну клавишу вроде `прривет` исправляются с той же
  отменой.
- **Языки.** Русский, английский, украинский и белорусский, в любом сочетании
  установленных раскладок.
- **Честно с кодом.** В терминалах и средах разработки по умолчанию только
  ручной перенабор, в играх Perekey выключен. Правила для программ и сайтов.
- **Любое сочетание.** Пресеты: один Shift, ⌥⇧ и ⌃⇧ как в Windows, ⌘⇧, две
  отдельные клавиши, Caps Lock. Или запишите своё — Perekey предупредит
  о конфликтах.
- **Не трогает пароли.** Поля паролей, Secure Input, строки, похожие на пароль
  или капчу, остаются как есть.
- **Ещё.** Смена регистра, транслитерация, вставка без форматирования, звуки.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-shortcuts-dark.png">
    <img src="docs/images/settings-shortcuts-light.png" width="720" alt="Настройки сочетаний: пресеты Shift, двойной Shift, Option + Shift, Control + Shift, Command + Shift и две клавиши">
  </picture>
</p>

## Приватность

- **Набранный текст не сохраняется.** Слово живёт в памяти, пока вы его
  набираете.
- **На этом Mac** в `~/Library/Application Support/Perekey/` лежат настройки
  и ваши списки слов («Мои», «Выученные», «Всегда исправлять»), счётчики
  правок, если вы их включили, и число слов каждого языка по программам.
  В счётчиках слов нет. Подробно — в разделе
  [What is stored](README.md#what-is-stored).
- **Сеть.** Единственный запрос — проверка обновлений:
  `https://tlgnkl.github.io/perekey/appcast.xml`, не чаще раза в день, без
  идентификаторов. Выключается в «Настройки» → «Основные». Подробно — в разделе
  [Network](README.md#network).
- **Нет** телеметрии, отправки слов и идентификаторов устройства.

## Автоматизация

Пауза, продолжение и режимы — по ссылке или из AppleScript, для Raycast,
Alfred и «Быстрых команд»:

    open perekey://pause?minutes=30
    open perekey://resume
    osascript -e 'tell application "Perekey" to set autoswitch to false'

Все команды — в разделе [Automation](README.md#automation).

## Участие

Сборка из исходников — в [README](README.md#build-from-source) и
[CONTRIBUTING.md](CONTRIBUTING.md). План — в [docs/PLAN.md](docs/PLAN.md).
Ложное переключение или программа, где Perekey ведёт себя странно?
[Создайте задачу](https://github.com/tlgnkl/perekey/issues/new/choose): для
обоих случаев есть формы. Уязвимости — по [SECURITY.md](SECURITY.md).

## Лицензия

[GPL-3.0-or-later](LICENSE).
