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
- Подписывать все выпуски одной подписью. С Developer ID Sparkle проверяет и
  EdDSA, и совпадение Team ID у старой и новой версии.
- Если у последнего релиза нет `appcast.xml` (не было секрета),
  `pages.yml` опубликует сайт без appcast, и проверки обновлений
  будут получать 404 до следующего релиза с ключом.
