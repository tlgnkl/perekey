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
