# Управляемые настройки (MDM)

Организация задаёт настройки Perekey профилем конфигурации. Профиль
пишет ключи в домен `app.perekey.Perekey` (payload `com.apple.ManagedClient.preferences`
или «Custom Settings» в Jamf, Kandji, Mosyle и т. п.).

Perekey учитывает только принудительные значения: их видно через
`CFPreferencesAppValueIsForced`. Значение, записанное через `defaults write`,
управляемым не считается. В настройках такой ключ выглядит выключенным
и заблокированным, с пометкой «Управляется вашей организацией».

## Ключи

| Ключ | Тип | Действие |
|---|---|---|
| `UpdatesDisabled` | Bool | `true`: Perekey не проверяет обновления, даже по кнопке. Sparkle не создаётся, приложение не обращается к сети. Переключатель «Проверять обновления автоматически» выключен и заблокирован, «Проверить обновления…» в меню скрыт. |
| `VoiceDisabled` | Bool | `true`: голосовой ввод выключен. Вкладка «Голос» остаётся, но выключатель неактивен, под ним надпись «Отключено администратором». Голос не обращается к сети и не скачивает модели. |
| `VoiceModelDownloadsDisabled` | Bool | `true`: кнопки «Скачать» у моделей речи нет, а список моделей объясняет, из какой папки они читаются. Модели берутся только из папки администратора `/Library/Application Support/Perekey/VoiceModels/<id>/`: те же файлы, что в каталоге Perekey, Whisper — с токенайзером в `tokenizer/`; рядом с моделью распознавания нужна папка `silero-vad/`. При первом использовании Perekey сверяет каждый файл по SHA-256 из каталога; модель с несовпавшим файлом считается повреждённой. |
| `VoiceCloudDisabled` | Bool | `true`: облачное распознавание и облачные языковые модели недоступны. Сейчас облака в Perekey нет, ключ зарезервирован. |
| `VoiceHistoryMaxDays` | Integer | Предел срока истории диктовок в днях. Срок, который выбрал пользователь, не больше предела: «день» — 1, «неделя» — 7, «месяц» — 30, срок длиннее предела заменяется самым длинным, который в него укладывается. `0`: история выключена, ничего не хранится, а то, что лежало на диске, стирается при запуске. |

Perekey читает профиль при запуске: профиль, поставленный на лету, начинает действовать после перезапуска Perekey.

Новые ключи добавлять в `ManagedSettings` (`Sources/PerekeyCore/UpdatePolicy.swift`)
и в эту таблицу. Имя ключа — существительное и состояние, как `UpdatesDisabled`.

## Пример профиля

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadDisplayName</key>
	<string>Perekey: без обновлений</string>
	<key>PayloadIdentifier</key>
	<string>org.example.perekey</string>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>EF5CE999-568E-464A-A494-D7DABFC450DB</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadScope</key>
	<string>System</string>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.ManagedClient.preferences</string>
			<key>PayloadIdentifier</key>
			<string>org.example.perekey.prefs</string>
			<key>PayloadUUID</key>
			<string>50763821-E130-4AC0-895D-790CCD177579</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadContent</key>
			<dict>
				<key>app.perekey.Perekey</key>
				<dict>
					<key>Forced</key>
					<array>
						<dict>
							<key>mcx_preference_settings</key>
							<dict>
								<key>UpdatesDisabled</key>
								<true/>
							</dict>
						</dict>
					</array>
				</dict>
			</dict>
		</dict>
	</array>
</dict>
</plist>
```

Профиль ставит MDM. Вручную его можно поставить двойным щелчком по
`.mobileconfig` и подтвердить в «Системных настройках» → «Основные» →
«Управление устройством». Проверить, что ключ принудительный:

```sh
defaults read /Library/Managed\ Preferences/app.perekey.Perekey UpdatesDisabled
```

После установки профиля перезапустить Perekey: настройки читаются при запуске.
