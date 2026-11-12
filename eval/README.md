# Данные стенда качества

Здесь лежит всё, что стенд читает, кроме кода: раскладки, манифесты наборов,
случаи, написанные руками, профили и планки. Устройство стенда, формат
случая и значение каждой метрики — в [docs/eval.md](../docs/eval.md). Правила
добавления — в [CONTRIBUTING.md](../CONTRIBUTING.md), раздел «Как добавить
случай и набор».

| Путь | Что |
|---|---|
| `layouts/` | Снимки раскладок. Копии файлов из `Tests/PerekeyCoreTests/Fixtures`; тест сверяет байты |
| `suites/*.suite.json` | Манифесты корпусных наборов: откуда текст, на каких раскладках, сколько токенов. Случаи из них строит `perekey-eval cases build` |
| `cases/*.jsonl` | Случаи, написанные руками: `flow.*` (поток программы) и `incidents.jsonl` (настоящие сбои) |
| `profiles.json` | Профили — веса наборов, похожие на человека: чат, разработчик, документы |
| `gates.json` | Планки: что не должно случиться и что не должно стать хуже |

Данные стенда и данные модели (`data/`) не пересекаются: сборщик модели
`eval/` не читает.

## Как запустить

```
scripts/quality.sh                    # уровень ci: собрать случаи, сыграть, проверить планки
QUALITY_BASE=origin/main scripts/quality.sh --self-check   # и сравнить с базой, и сыграть мутантов
scripts/quality.sh --full --report html                     # уровень full и отчёт HTML
```

Нужны источники: `scripts/fetch-data.sh lexicon wikifreq pairs heldout`.
Подробности и коды выхода — в [docs/eval.md](../docs/eval.md), раздел
«Планки и CI».

## Как добавить сбой

Сбой — это одна строка в `cases/incidents.jsonl`. Пока Perekey ошибается на
ней, статус `open`: случай играется и виден в отчёте, но планку не держит.
Когда правка влита, статус `fixed`, и случай входит в планку «ноль»:
вернувшийся сбой делает шаг CI красным.

1. Откройте issue «False switch» (`.github/ISSUE_TEMPLATE/false-switch.yml`).
   Если текст в нём личный, замените его похожим выдуманным: в репозиторий
   личный текст не попадает.
2. Перенесите поля issue в случай:

   | Поле issue | Куда в случае |
   |---|---|
   | What you typed | `script`: шаг `{"type":"<текст> ","on":"<раскладка, в которую целились пальцы>"}`. Пробел или знак в конце — то, чем человек закончил слово |
   | What Perekey did | `meta.why`: одной фразой, что вышло и что нужно |
   | Classifier decision | В `meta.why`, если помогает понять случай. Сами числа — не в случай |
   | App | `env.app`, идентификатор программы (`com.apple.TextEdit`, `com.googlecode.iterm2`). Не знаете идентификатор — оставьте умолчание и напишите название программы в `meta.why` |
   | Layouts enabled | `layouts` (имена снимков из `layouts/`) и `start` — раскладка, активная в начале |
   | Mode | `env.mode`: `auto`, `manualOnly`, `off`. Hotkey — `manualOnly` и шаг `{"hotkey":"convertLastWord"}` |
   | Perekey and macOS version | `meta.version` |
   | Номер issue | `meta.issue` (`"#123"`) |

3. Заполните `want` — текст, который человек хотел увидеть, — и `tokens`:
   по объекту на каждое слово измеряемой части. `err` — ошибка человека:
   `none`, если он набрал верно, а Perekey испортил (ложное переключение);
   `layout`, если он набрал не в той раскладке, а Perekey не исправил.
   `scenario` — `clean.cold` для первого и `slip.cold` для второго.
4. Поставьте `meta.status`: `open` для сбоя, который ещё не починен.
5. Впишите любой `id` в форме `incidents/<сценарий>/000000000000`, запустите
   `perekey-eval cases check eval/cases/incidents.jsonl` и подставьте
   `id`, который назовёт команда (хэш содержимого). Строка должна быть
   канонической: отсортированные ключи, без пробелов. Проверка говорит, если
   это не так.
6. Убедитесь, что сбой воспроизводится:
   `perekey-eval case --cases eval/cases/incidents.jsonl --id <id> --model .build/model`
   печатает события, текст поля и исход каждого токена. Для ложного
   переключения нужен исход `harm`, для пропуска — `miss`.
7. Когда правка влита, смените `meta.status` на `fixed` в том же PR. После
   смены `id` не меняется: он считается не по `meta`.

Пример:

```
{"id":"incidents/clean.cold/e05fb8b3d083","layouts":["ABC","Russian"],"meta":{"issue":"#31","status":"open","why":"an abbreviation in capitals with a comma, typed as meant, stays"},"scenario":"clean.cold","script":[{"on":"ABC","type":"DDG, "}],"split":"dev","start":"ABC","suite":"incidents","tokens":[{"err":"none","lang":"en","t":"DDG,"}],"v":1,"want":"DDG,"}
```

## Как добавить набор

Корпусный набор — манифест `suites/<имя>.suite.json`. Поля описаны в
docs/eval.md, раздел «Корпусные наборы».

1. Источник закрепите хэшем в `scripts/fetch-data.sh`, запишите в
   `data/SOURCES.md` с лицензией и отнесите к группе `heldout` или `bench`.
   Источник с неясной лицензией в репозиторий не попадает.
2. Скопируйте манифест ближайшего набора, смените `suite` (имя файла равно
   полю `suite`), `source`, `layoutSets`, `scenarios`, `tiers`.
3. Выберите `tiers.ci` так, чтобы набор влез в бюджет шага CI (docs/eval.md,
   «Планки и CI»). Набор из источника, которого CI не качает, в `ci` не идёт.
4. Соберите и проверьте:

   ```
   perekey-eval cases build --suites eval/suites --only <имя> --out .build/quality/cases/ci
   perekey-eval cases check .build/quality/cases/ci/<имя>.jsonl
   ```

5. Если набор должен гейтить, добавьте строку в `gates.json` (docs/eval.md,
   «Планки и CI»). В `zero` идёт только то, что уже 0 на `main`.
6. Если набор должен входить в профиль, впишите его в `profiles.json` с весом.
   Наборы классов в профили не входят.

Случаи, написанные руками (`flow.*`), — файл `cases/flow.<имя>.jsonl` по тем же
правилам, что и сбои: `scoring: case`, `checks` вместо `tokens`.
