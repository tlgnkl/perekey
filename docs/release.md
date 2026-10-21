# Выпуск и обновления через Sparkle

Perekey обновляется через Sparkle 2. Версия Sparkle задана один раз — в
`binaryTarget` в `Package.swift`. `scripts/appcast.sh` берёт оттуда же адрес
архива и контрольную сумму, поэтому второй номер версии держать не нужно.

## Что настроить один раз

1. Скачать инструменты Sparkle той же версии, что в `Package.swift`:

   ```sh
   curl -LO https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip
   shasum -a 256 Sparkle-for-Swift-Package-Manager.zip   # сверить с checksum в Package.swift
   unzip Sparkle-for-Swift-Package-Manager.zip -d sparkle
   ```

2. Создать пару ключей EdDSA. Закрытый ключ ляжет в связку ключей входа:

   ```sh
   sparkle/bin/generate_keys --account perekey
   ```

   Команда печатает открытый ключ (44 символа base64).

3. Вписать открытый ключ в `Support/Info.plist` вместо `TO-CONFIGURE`
   (ключ `SUPublicEDKey`) и закоммитить. Открытый ключ не секрет.
   Пока там заглушка, приложение считает обновления не настроенными
   и Sparkle не запускает.

4. Выгрузить закрытый ключ и положить его в секрет CI:

   ```sh
   sparkle/bin/generate_keys --account perekey -x perekey-ed25519.key
   gh secret set SPARKLE_ED_PRIVATE_KEY < perekey-ed25519.key
   rm -P perekey-ed25519.key
   ```

   Закрытый ключ хранится только в секрете `SPARKLE_ED_PRIVATE_KEY` и в
   связке ключей того, кто его создал. В репозиторий его не класть.
   Потеря ключа означает, что установленные копии больше не примут
   обновление: придётся выпускать новую версию с новым ключом, а
   пользователи поставят её вручную.

5. Включить GitHub Pages: Settings → Pages → Source: «GitHub Actions».
   Appcast будет по адресу `SUFeedURL`:
   `https://tlgnkl.github.io/perekey/appcast.xml`. Если позже появится свой
   домен, сменить `SUFeedURL` в `Info.plist`, `UpdateFeed.url` и раздел
   «Network» в README одним коммитом: GitHub будет перенаправлять старый
   адрес, но Little Snitch покажет два хоста.

## Подпись

`release.yml` подписывает приложение первой подписью, для которой заведены
секреты:

| Подпись | Секреты | Нотаризация | Разрешения после обновления |
|---|---|---|---|
| Developer ID | `DEVELOPER_ID_*`, `NOTARY_*` | да | остаются |
| «Perekey Release», самоподписанная | `PEREKEY_RELEASE_CERT_*` | нет, в заметках шаги «Open Anyway» | остаются |
| ad hoc | нет | нет, в заметках шаги «Open Anyway» | теряются |

macOS привязывает «Универсальный доступ», «Мониторинг ввода» и микрофон к
designated requirement подписи. У ad hoc он равен хэшу кода (`cdhash`) и
меняется в каждой сборке. У «Perekey Release» он один для всех сборок:
`identifier "app.perekey.Perekey" and certificate leaf = H"<SHA-1 сертификата>"`.
Gatekeeper «Perekey Release» не доверяет, как и ad hoc: первый запуск
по-прежнему через «Open Anyway». DMG этой подписью не подписывается — для
Gatekeeper она ничего не меняет.

### Завести «Perekey Release» (один раз)

1. Создать ключ вне репозитория:

   ```sh
   scripts/release-cert.sh ~/perekey-release
   ```

   Скрипт кладёт в каталог `.p12`, его случайный пароль, `.p12` в base64 и
   открытый сертификат. Сам он ничего в GitHub не отправляет.
2. Settings → Environments → New environment `release`. Включить «Required
   reviewers» (владелец) и в «Deployment branches and tags» оставить только
   теги `v*`.
3. Settings → Rules → Rulesets → New tag ruleset. Цель — `v*`, включить
   «Restrict creations», «Restrict updates» и «Restrict deletions», в «Bypass
   list» — только владелец. Так тег выпуска ставит только он.
4. Положить секреты в окружение, а не в секреты репозитория:

   ```sh
   gh secret set PEREKEY_RELEASE_CERT_P12 --env release < ~/perekey-release/perekey-release.p12.base64
   gh secret set PEREKEY_RELEASE_CERT_PASSWORD --env release < ~/perekey-release/perekey-release.p12.password
   ```

   Туда же стоит перенести `SPARKLE_ED_PRIVATE_KEY` (`--env release`) и
   удалить его копию из секретов репозитория.
5. Скопировать `perekey-release.p12` и `perekey-release.p12.password` в
   офлайн-хранилище: зашифрованный диск или менеджер паролей.
6. Удалить каталог: `rm -P ~/perekey-release/* && rmdir ~/perekey-release`.

Задание `release.yml` идёт в окружении `release`, поэтому каждый выпуск ждёт
подтверждения владельца. Сертификат CI кладёт во временную связку ключей со
случайным паролем и удаляет её последним шагом, даже если сборка упала.

Чем опасен этот ключ:

- Отозвать его нельзя. С ключом любая программа подпишется как Perekey и
  получит её разрешения, в том числе «Мониторинг ввода». Поэтому ключ живёт
  только в окружении `release` и в офлайн-копии.
- Обновление через Sparkle с одним этим ключом не выпустить, но только
  благодаря `SUVerifyUpdateBeforeExtraction` в `Info.plist`. Без него Sparkle 2
  принимает новый ключ EdDSA из обновления, если подпись кода совпала с
  установленной копией: ключ Release и доступ на запись к appcast (Pages или
  релизы) дали бы вредоносное обновление. С этим ключом каждое обновление
  обязано быть подписано прежним ключом EdDSA до распаковки. Запасной путь
  Sparkle через подпись кода требует Team ID Developer ID, а у «Perekey
  Release» его нет. Цена: сменить ключ EdDSA нельзя, потерянный ключ
  означает ручную переустановку у всех. Флаг действует со сборки, в которой
  он уже есть; ad hoc-сборки 0.1.x защищены иначе — их requirement не
  подделать.
- Утечка ключа EdDSA (`SPARKLE_ED_PRIVATE_KEY`) вместе с доступом к appcast
  по-прежнему даёт вредоносное обновление. Поэтому оба ключа живут только в
  окружении `release` и в офлайн-копиях, теги `v*` защищены правилом, а
  выпуск ждёт подтверждения.
- Новый сертификат — новый designated requirement: каждый пользователь заново
  выдаст разрешения. Сертификат не пересоздавать, потерянный восстановить из
  офлайн-копии.
- Срок — 100 лет. `codesign` не подписывает просроченным сертификатом, и
  `release.yml` падает на шаге импорта, а не в середине сборки.

### Подписать локально

Perekey Dev, «Perekey Release» и ad hoc у `scripts/bundle.sh` задаются
переменными окружения:

| Подпись | Как |
|---|---|
| Perekey Dev | по умолчанию, если есть связка `scripts/dev-cert.sh` |
| ad hoc | `SIGN_IDENTITY=-` |
| «Perekey Release» | `SIGN_IDENTITY="Perekey Release" SIGN_KEYCHAIN=<связка>` |

Ключ Release не класть в связку Perekey Dev: у неё открытый пароль. Своя
связка:

```sh
kc=~/Library/Keychains/perekey-release.keychain-db
security create-keychain "$kc"                   # спросит пароль связки
security import perekey-release.p12 -k "$kc" -T /usr/bin/codesign \
    -P "$(cat perekey-release.p12.password)"
security set-key-partition-list -S apple-tool:,apple: -s "$kc"   # снова пароль связки
security lock-keychain "$kc"
```

Подписать сборку и проверить requirement:

```sh
security unlock-keychain "$kc"
SIGN_IDENTITY="Perekey Release" SIGN_KEYCHAIN="$kc" scripts/bundle.sh
codesign -d -r- .build/app/Perekey.app
security lock-keychain "$kc"
```

У Perekey Dev и «Perekey Release» один bundle ID. Запуск сборки с другой
подписью перетирает записи TCC, и разрешения придётся выдать заново.

## Как выпустить версию

0. Перед тегом пройти чек-лист ниже («Чек-лист выпуска с голосом»).
1. В `CHANGELOG.md` перенести пункты из `[Unreleased]` в новый раздел
   `## [X.Y.Z] - ГГГГ-ММ-ДД`. Внизу файла добавить ссылку на тег и сдвинуть
   ссылку `[Unreleased]`.
2. Проверить заметки к выпуску: `scripts/release-notes.sh X.Y.Z`.
3. Влить это в `main`.
4. Поставить тег: `git tag -a vX.Y.Z -m "Perekey X.Y.Z"` и
   `git push origin vX.Y.Z`.
5. Подтвердить запуск `release.yml` в окружении `release` (Actions → запуск →
   «Review deployments») и дождаться его. Он проверяет раздел в
   `CHANGELOG.md` до сборки: без раздела или без даты выпуск падает сразу.
6. Проверить страницу выпуска и ссылку
   `https://github.com/tlgnkl/perekey/releases/latest/download/Perekey.dmg`.
7. Обновить Homebrew tap по `packaging/README.md`.

Заметки к выпуску — раздел версии из `CHANGELOG.md` и блок «Install» из
`scripts/release-notes.sh`. У сборки без нотаризации в блоке есть шаги «Open
Anyway». К выпуску прикладываются `Perekey-X.Y.Z.dmg`, его `.sha256` и тот же
образ под именем `Perekey.dmg`: на него ведут README и сайт, а
`releases/latest/download/Perekey.dmg` всегда отдаёт новейший.

Выпуск не помечать как pre-release: тогда `releases/latest` на него не
указывает, и ссылка «Скачать» ведёт на прежнюю версию или в 404.

## Чек-лист выпуска с голосом

С 0.2.0 выпуск собирается с `PEREKEY_VOICE=1`: `release.yml` задаёт флаг на
всё задание, собирает `.build/voice-universal` и кладёт в DMG его
`Perekey.app`. Флаг в `Package.swift` остаётся: сборки без голоса нужны тестам
и `build-model.sh`, `bench.sh`, `eval.sh`. Оба среза (arm64 и x86_64) содержат
FluidAudio и WhisperKit, потому что SwiftPM не подключает пакет под одну
архитектуру; на Intel и на macOS 14 голос выключает `VoiceHost.isSupported`.

1. Сухой прогон локально, ad hoc подписью (настоящий ключ — только в CI):

   ```sh
   export PEREKEY_VOICE=1 VERSION=X.Y.Z BUILD=1 SIGN_IDENTITY=-
   scripts/build-model.sh --out .build/universal/model   # один раз, нужен scripts/fetch-data.sh lexicon wikifreq
   scripts/build-universal.sh
   scripts/check-release-app.sh
   scripts/dmg.sh .build/voice-universal/app/Perekey.app
   ```

   `check-release-app.sh` проверяет то же, что CI-задание `release-build`:
   оба среза с движками речи, `minos` срезов равен `LSMinimumSystemVersion`,
   в `Info.plist` есть `NSMicrophoneUsageDescription` и
   `NSAudioCaptureUsageDescription`, у подписи есть право
   `com.apple.security.device.audio-input`, в приложении нет ресурсных бандлов,
   подпись цела.
2. Размер DMG записать в заметки. Порога нет, только замер (0.1.1 весил 25,7 МБ,
   0.2.0 — около 38,7 МБ: добавились библиотеки речи, модели в образ не входят).
3. Проверить голос в выпускной сборке, подписанной «Perekey Release» (не в
   сборке из `swift build`): установить DMG, выдать «Мониторинг ввода»,
   «Универсальный доступ», «Микрофон»; скачать модель, продиктовать фразу в
   TextEdit; записать минуту с YouTube и своего голоса, проверить «Запись
   системного звука» и две дорожки в окне «Расшифровки».
4. Проверка A2: поставить предыдущую сборку «Perekey Release», выдать
   разрешения, обновить поверх новой (через Sparkle или вручную): разрешения
   («Универсальный доступ», «Мониторинг ввода», «Микрофон», «Запись
   системного звука») остаются, окно разрешений не появляется.
5. На Mac с Intel или macOS 14: приложение запускается, вкладка «Голос»
   объясняет, что нужны Apple Silicon и macOS 15, пункта записи созвона нет,
   перенабор работает как в 0.1.x.
6. «Благодарности»: список в `README.md`, `README.ru.md` и
   `Support/*.lproj/Credits.rtf` (окно «О Perekey») совпадает с моделями
   каталога (`ModelCatalogData.swift`) и пакетами в
   `Support/voice/Package.resolved`. Новая модель или пакет — новая строка со
   своей лицензией; CC-BY требует указать автора, ссылку на лицензию и пометку,
   что файлы изменены. Лицензию брать из карточки модели на Hugging Face и из
   `LICENSE` пакета, а не из памяти.
7. `scripts/test.sh` с `PEREKEY_VOICE=1` и без, `scripts/check-strings.sh`.

## Как CI подписывает appcast

`release.yml` на теге `v*` собирает DMG и выполняет:

```sh
TAG="$GITHUB_REF_NAME" scripts/appcast.sh ".build/dmg/Perekey-$VERSION.dmg"
```

Скрипт проверяет, что в приложении внутри DMG настоящий `SUPublicEDKey`,
скачивает zip Sparkle из `Package.swift` со сверкой суммы и вызывает:

```sh
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | generate_appcast \
    --ed-key-file - \
    --download-url-prefix "https://github.com/tlgnkl/perekey/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/tlgnkl/perekey/releases/tag/$TAG" \
    --maximum-deltas 0 \
    -o .build/appcast/appcast.xml \
    .build/appcast/archives
```

Ключ идёт через stdin и не попадает ни в аргументы, ни в файлы.
`generate_appcast` подписывает DMG (`sparkle:edSignature`) и пишет
`sparkle:minimumSystemVersion` из `LSMinimumSystemVersion`.

Дальше `release.yml` прикладывает `appcast.xml` к релизу и запускает
`pages.yml`. Тот скачивает `appcast.xml` из релиза с пометкой «Latest» и
публикует его рядом с `site/`.

Проверить локально без настоящего ключа (`openssl` создаёт одноразовую пару):

```sh
openssl genpkey -algorithm ed25519 -outform DER -out /tmp/k.der
openssl pkey -inform DER -in /tmp/k.der -pubout -outform DER | tail -c 32 | base64   # открытый
tail -c 32 /tmp/k.der | base64                                                      # закрытый
SPARKLE_PUBLIC_ED_KEY=<открытый> VERSION=9.9.0 BUILD=99 scripts/bundle.sh
VERSION=9.9.0 scripts/dmg.sh .build/app/Perekey.app
SPARKLE_ED_PRIVATE_KEY=<закрытый> scripts/appcast.sh .build/dmg/Perekey-9.9.0.dmg
```

## Правила

- `CFBundleVersion` (в CI это `GITHUB_RUN_NUMBER`) растёт с каждым выпуском:
  Sparkle сравнивает именно его.
- В appcast одна запись — новейшая версия. Sparkle больше не нужно.
- Описание изменений не встраивается в appcast и не грузится отдельным
  запросом: проверка остаётся одним GET. Кнопка «История версий» в окне
  Sparkle открывает страницу релиза в браузере.
- В бандл идёт модель — файл на язык из `data/languages`: сейчас
  `Contents/Resources/ru.pklm`, `en.pklm`, `uk.pklm` и `be.pklm`. Приложение
  включает ровно те языки, файлы которых нашло в бандле. `release.yml`
  собирает модели из кэша `scripts/fetch-data.sh lexicon wikifreq` отдельным
  шагом до импорта сертификата подписи: пакеты Python для
  `wiki-freq.py` ставятся с точными версиями и хэшами
  (`scripts/wiki-freq.requirements.txt`, `pip --require-hashes`), и ничего
  стороннего не запускается, пока сертификат лежит в открытой связке. Хэш
  каждого файла, включённого или нет, сверен с `data/model.sha256`. Приложение, которое
  ждёт прежний `perekey.model`, новую модель не найдёт: старые сборки и
  новые файлы не смешивать.
- Подписывать все выпуски одной подписью. С `SUVerifyUpdateBeforeExtraction`
  Sparkle 2 принимает только архив, подписанный ключом EdDSA установленной
  копии; подпись кода новой версии должна быть целой, но может быть другой.
  Поэтому смена подписи (ad hoc → «Perekey Release» → Developer ID) при том
  же ключе EdDSA обновление не ломает. Разрешения macOS при смене подписи
  теряются.
- Если у последнего релиза нет `appcast.xml` (не было секрета),
  `pages.yml` опубликует сайт без appcast, и проверки обновлений
  будут получать 404 до следующего релиза с ключом.
