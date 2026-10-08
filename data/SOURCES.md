# Источники данных

Здесь записаны источник и лицензия каждого словаря и корпуса (раздел «Чистая
комната» в `docs/PLAN.md`). Данные Caramba (`latest.clm`, `caramba.redb`) не
используем ни в каком виде.

Скачивает всё `scripts/fetch-data.sh` в `.build/data-cache` (или в
`$PEREKEY_DATA_CACHE`). Скачанное в git не кладём.

Проверено 08.10.2026. Это не юридическое заключение: ниже пересказ текстов
лицензий и официальных разъяснений со ссылками.

## Итог

| Что | Источник | Лицензия | Группа в скрипте |
|---|---|---|---|
| Ранг частоты ru и en | wordfreq 3.2 | данные CC BY-SA 4.0, код Apache-2.0 | `lexicon` |
| Словоформы ru | Hunspell ru_RU (Лебедев) из LibreOffice | BSD-подобная | `lexicon` |
| Словоформы en | SCOWL / ESDB, en_US-large | разрешительная (HPND-подобная) | `lexicon` |
| Символьные n-граммы | Википедия ru и en, снимок 2023-11-01 | CC BY-SA 4.0 (+ GFDL) | `text` |
| Отложенный корпус | Tatoeba, Stack Exchange, GeoNames, синтетика | CC0, CC BY 2.0 FR, CC BY-SA, CC BY 4.0 | `heldout`, `heavy` |
| Запасной словарь ru | OpenCorpora | CC BY-SA 3.0 | `fallback`, только после юриста |

Модель — переработка материалов под CC BY-SA 4.0 плюс разрешительные данные.
Её лицензия — CC BY-SA 4.0. Внутри приложения она распространяется под GPLv3
по одностороннему разрешению Creative Commons.

## Совместимость лицензий

### CC BY-SA 4.0 → GPLv3

- Creative Commons 8 октября 2015 года объявила GPLv3 «BY-SA Compatible
  License» для версии 4.0. Разрешение одностороннее: переработку BY-SA 4.0
  можно выпустить под GPLv3, обратно нельзя.
  [Объявление CC](https://creativecommons.org/2015/10/08/cc-by-sa-4-0-now-one-way-compatible-with-gplv3/),
  [список совместимых лицензий](https://creativecommons.org/share-your-work/licensing-considerations/compatible-licenses/).
- Основание в тексте лицензии: BY-SA 4.0 §3(b)(1) — «The Adapter's License You
  apply must be a Creative Commons license with the same License Elements,
  this version or later, or a BY-SA Compatible License».
  [Legal code 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode).
- В совмещённой работе действуют обе лицензии. Условия BY-SA можно выполнить
  способом GPLv3 (§2(a)(5)(B)).
  [CC wiki: ShareAlike compatibility: GPLv3](https://wiki.creativecommons.org/wiki/ShareAlike_compatibility:_GPLv3).
- **Ограничение «or later».** CC внесла в список только GPLv3. Поэтому
  переработку BY-SA нельзя выпустить под «GPLv3 or any later version». FSF
  советует назначить посредника по §14 GPLv3.
  [Список лицензий FSF](https://www.gnu.org/licenses/license-list.html#ccbysa),
  [блог FSF](https://www.fsf.org/blogs/licensing/creative-commons-by-sa-4-0-declared-one-way-compatible-with-gnu-gpl-version-3).
  Следствие: код Perekey остаётся GPL-3.0-or-later, а сборка с моделью
  фактически под GPLv3.

### CC BY-SA 3.0 → 4.0 → GPLv3 (OpenCorpora, старые правки Википедии)

План называет OpenCorpora несовместимой. Это верно для прямого пути и спорно
для пути через 4.0.

- BY-SA 3.0 §4(b): переработку можно распространять под «(ii) a later version
  of this License with the same License Elements as this License». License
  Elements — Attribution и ShareAlike (§1(d)). BY-SA 4.0 подходит.
  [Legal code 3.0](https://creativecommons.org/licenses/by-sa/3.0/legalcode).
- CC подтверждает: вклад в переработку BY-SA 3.0 можно лицензировать под
  «BY-SA 3.0, or a later version of the BY-SA license». Там же: «Currently, no
  non-CC licenses have been designated as compatible with BY-SA 3.0». Значит,
  прямо 3.0 → GPLv3 нельзя.
  [Compatible licenses](https://creativecommons.org/share-your-work/licensing-considerations/compatible-licenses/).
- Wikimedia в 2023 году перевела тексты на 4.0 этим же пунктом 4(b): после
  правки статью можно использовать под 4.0.
  [Legal note](https://meta.wikimedia.org/wiki/Terms_of_use/Creative_Commons_4.0/Legal_note).

**Вывод.** Модель, *производная* от данных под 3.0, по тексту §4(b)(ii) может
выйти под BY-SA 4.0. Переработку под 4.0 по §3(b)(1) можно включить в GPLv3.
Слабые места цепочки:

1. CC не разъясняла двухшаговый путь 3.0 → 4.0 → GPLv3. Официально его никто
   не подтвердил и не запретил.
2. По §8(b) BY-SA 3.0 исходный материал доходит до получателя под 3.0.
   Переход на 4.0 покрывает нашу переработку, но не сами записи источника.
3. Нужна именно переработка (Adaptation). Голая копия списка форм ею не
   является.

Решение: OpenCorpora держим запасным источником. Использовать — только после
консультации юриста.

### Охраняется ли частотная таблица

- Факты авторским правом не охраняются. CC: «Facts are not subject to
  copyright», условия лицензии касаются структуры базы и охраняемого
  содержимого. [CC wiki: Data](https://wiki.creativecommons.org/wiki/Data),
  [CC FAQ](https://creativecommons.org/faq/).
- BY-SA 4.0 считает переработкой только то, что «requiring permission under
  the Copyright and Similar Rights». Если для частот и n-грамм разрешение не
  нужно, ShareAlike их не касается.
- Но есть право изготовителя базы данных. В ЕС — директива 96/9/EC. В России —
  ст. 1334 ГК РФ (база от 10 000 элементов предполагается охраняемой).
  Словарь словоформ под это подходит.
- BY-SA 4.0 прямо лицензирует sui generis права (раздел 4). BY-SA 3.0 Unported
  — нет. CC пишет, что тогда условия 3.0 могут не применяться вовсе, а в
  некоторых странах возможна подразумеваемая лицензия.
  [CC wiki: Data](https://wiki.creativecommons.org/wiki/Data).

Итог: охраняемость счётчиков неясна, это зависит от страны. Поэтому всё равно
выполняем условия лицензий: указываем авторство и лицензируем модель под BY-SA
4.0. Так безопасно при любом ответе.

### GFDL в Википедии

Новые тексты Википедии лицензируются под CC BY-SA 4.0 **и** GFDL. «Reusers
may comply with either license or both».
[Terms of Use §7](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use).
Мы берём только ветку CC BY-SA 4.0. GFDL нам не нужна, её совместимость с GPL
не важна. Тексты «только под GFDL» Википедия импортировать запрещает.

## Кандидаты

### Используем

| Источник | Лицензия | Объём | Формат | Что берём | Вердикт |
|---|---|---|---|---|---|
| [wordfreq](https://github.com/rspeer/wordfreq) 3.2, `large_ru`, `large_en` | Данные CC BY-SA 4.0, код Apache-2.0 ([README](https://github.com/rspeer/wordfreq#license)) | ru 713 447 форм, 4,5 МБ; en 321 180 форм, 1,5 МБ | msgpack.gz, 800 корзин centibel | Ранг частоты, дополнительные формы | Да |
| [Hunspell ru_RU](https://github.com/LibreOffice/dictionaries/tree/master/ru_RU), А. Лебедев | BSD-подобная ([README_ru_RU.txt](https://github.com/LibreOffice/dictionaries/blob/master/ru_RU/README_ru_RU.txt)) | 146 269 основ, из них 7 347 с «ё» | `.dic` + `.aff` | Словоформы раскрытием аффиксов | Да |
| [SCOWL / ESDB](https://github.com/en-wl/wordlist) `en_US-large` | Разрешительная, без доп. условий для официальных словарей ([Copyright](https://github.com/en-wl/wordlist/blob/v2/Copyright)) | 0,84 МБ `.dic` | Hunspell zip | Словоформы en | Да |
| [Википедия](https://huggingface.co/datasets/wikimedia/wikipedia) ru и en, снимок 20231101, по одному файлу | CC BY-SA 4.0 + GFDL (ToU) | ru 171 МБ, en 188 МБ parquet | parquet, чистый текст | Символьные 4/5-граммы; часть статей — в отложенный корпус | Да |

**wordfreq.** Код под Apache-2.0, а не MIT; с GPLv3 совместим. Данные
собраны из нескольких доменов
([Exquisite Corpus](https://github.com/LuminosoInsight/exquisite-corpus)).
Для ru: Википедия, субтитры (OpenSubtitles 2018), новости (NewsCrawl,
GlobalVoices), Google Books Ngrams 2012, Twitter. Для en ещё Reddit и OSCAR
(веб). Автор выпускает итоговые частоты под CC BY-SA 4.0 и перечисляет условия
источников: Google Books — «freely used for any purpose», SUBTLEX — разрешение
на любое использование при указании авторов, OpenSubtitles — «may be used with
attribution». Данные заморожены на 2021 году
([SUNSET.md](https://github.com/rspeer/wordfreq/blob/master/SUNSET.md)).
Автор просит не конвертировать списки в CSV без атрибуции. Мы переносим
атрибуцию в заголовок модели и в окно «Лицензии».

**Hunspell ru_RU.** Текст в LibreOffice — «Copyright (c) 1997-2008, Alexander
I. Lebedev», условия BSD с пунктом «Modified versions must be clearly marked
as such». Такой пункт GPLv3 допускает (§7(c)). Старая версия лицензии
(1997–2004) разрешала распространять изменения только патчами
([копия в Gentoo](https://ftp.riken.jp/Linux/gentoo-portage/licenses/myspell-ru_RU-AlexanderLebedev)).
Берём именно копию LibreOffice с BSD-текстом. Частот в Hunspell нет: формы без
ранга в wordfreq получают нижнюю корзину.

**Википедия.** Снимок 20231101 сделан после перехода на 4.0 (июнь 2023).
Статьи, которые не правились после перехода, формально остаются под 3.0 — та
же цепочка, что у OpenCorpora. Для символьных n-грамм риск мал: статистика букв
вряд ли переработка в смысле авторского права. Запасной путь без Википедии —
строить n-граммы по списку wordfreq с весами частот.

### Для отложенного корпуса

Отложенный корпус не входит в приложение. Если мы его не распространяем,
условия атрибуции и ShareAlike не срабатывают. Выборку для CI в репозиторий
кладём только из CC0 и синтетики.

| Категория | Источник | Лицензия | Вердикт |
|---|---|---|---|
| Проза | Википедия: статьи с `id % 20 == 0` из того же файла, исключены из обучения | CC BY-SA 4.0 | Да |
| Чат, короткие фразы | [Tatoeba](https://tatoeba.org/en/terms_of_use): `sentences_CC0` и `rus/eng_sentences` | CC0; остальные CC BY 2.0 FR | Да. В репозиторий — только CC0 |
| Смешанный ru+en, код | Дампы Stack Exchange 2024-04 на [archive.org](https://archive.org/details/stackexchange): `russian.stackexchange`, `rus.stackexchange`; `ru.stackoverflow` (1 ГБ) — в `heavy` | CC BY-SA 2.5/3.0/4.0, по посту в `ContentLicense` | Да, только локально и в CI, не в репозиторий |
| Имена, топонимы | [GeoNames](https://www.geonames.org/export/) `cities15000` | CC BY 4.0 | Да |
| Код | Исходники Perekey (наши, GPL-3.0-or-later) + блоки кода из Stack Exchange | — | Да |
| URL, email, пути | Синтетика с фиксированным seed | — | Да |
| Строки-пароли, капча | Синтетика с фиксированным seed | — | Да |
| Опечатки (этап 4а) | Синтетика по схеме клавиатуры | — | Да |

Tatoeba и GeoNames обновляются без версий. Скрипт их не пиннит, а записывает
хэш скачанного в `MANIFEST.sha256`. Для воспроизводимого прогона корпус
собирается один раз и хранится как артефакт CI.

У Stack Exchange свои требования к атрибуции: ссылка на вопрос и на профиль
автора ([license.txt](https://archive.org/download/stackexchange/license.txt)).
Они нужны, только если мы публикуем тексты. Поэтому посты в репозиторий не
кладём.

### Отклонены или в запасе

| Источник | Лицензия | Проблема | Вердикт |
|---|---|---|---|
| [OpenCorpora](https://opencorpora.org/?page=downloads), словарь ~5 млн форм | CC BY-SA 3.0 ([подвал сайта](https://github.com/OpenCorpora/opencorpora/blob/master/templates/footer.tpl)) | Цепочка 3.0 → 4.0 → GPLv3 не подтверждена (см. выше). Словарь — переработка словаря АОТ ([обсуждение](https://qna.habr.com/q/28343)) | Запас, после юриста |
| [pymorphy3-dicts-ru](https://pypi.org/project/pymorphy3-dicts-ru/) / pymorphy2-dicts | Код MIT, данные CC BY-SA 3.0 | То же, что OpenCorpora, плюс бинарный DAWG | Нет. При нужде брать XML OpenCorpora |
| [АОТ](https://github.com/sokirko74/aot) (морфология Сокирко) | LGPL-2.1 в репозитории `aot`; в [`morph_dict`](https://github.com/sokirko74/morph_dict) файла лицензии нет | LGPL совместима с GPLv3. Но словарь основан на словаре Зализняка; права на основу не ясны | Запас: дополнить ru формами с «ё» |
| Hunspell [ru-aot](https://packages.altlinux.org/en/p9/srpms/hunspell-ru-aot) (Я. Резцов) | LGPL по данным упаковщиков ([SourceForge seman](https://sourceforge.net/projects/seman/): LGPLv2) | То же, что АОТ | Запас |
| [Leipzig Corpora Collection](https://wortschatz.uni-leipzig.de/en/usage) | Загрузки CC BY, остальное CC BY-NC | Предложения из новостей и веба; права на сами тексты Лейпциг не передаёт. Страницу условий проверить не удалось (защита от ботов) | Нет |
| [Taiga](https://tatianashavrina.github.io/taiga_site/) | Заявлена CC BY-SA 3.0 | Тексты журналов и соцсетей; права авторов не очищены | Нет |
| [OpenSubtitles / OPUS](https://opus.nlpl.eu/OpenSubtitles.php) | Лицензии нет, просьба указать источник | Субтитры — производные от фильмов | Нет. Косвенно есть в wordfreq как частоты |
| Корпуса из Common Crawl (OSCAR, CC-100, mC4, FineWeb-2, CulturaX) | Обёртка CC0 или ODC-By | По [условиям Common Crawl](https://commoncrawl.org/terms-of-use) права третьих лиц на тексты остаются, риск на пользователе | Нет |
| Tatoeba (не CC0) в модели | CC BY 2.0 FR | Список FSF называет совместимой с GPL CC BY 4.0, про версию 2.0 не говорит. Модели фразы не нужны | Только отложенный корпус |

## Что выполнить при выпуске

1. Положить в бандл файл лицензий данных: авторы, ссылки, тексты BY-SA 4.0 и
   BSD-лицензии Лебедева.
2. Записать в заголовок модели список источников и «CC BY-SA 4.0».
3. Пометить словоформы ru как изменённую версию словаря Лебедева.
4. Указать в README: код — GPL-3.0-or-later, модель — CC BY-SA 4.0, сборка —
   GPLv3.

## Открытые вопросы (к юристу)

1. Можно ли пройти 3.0 → 4.0 → GPLv3 для OpenCorpora? От ответа зависит, нужен
   ли запасной словарь.
2. Охраняются ли частоты и n-граммы правом изготовителя базы (ст. 1334 ГК РФ,
   директива 96/9/EC)? Действует ли BY-SA 3.0 Unported на такие права?
3. Назначать ли посредника по §14 GPLv3 (например, Creative Commons), чтобы
   сборка с моделью могла перейти на будущую GPL?
4. Под какой лицензией принимать правки списков в `data/<язык>/`: только
   GPL-3.0-or-later или ещё и CC BY-SA 4.0, чтобы модель оставалась под BY-SA
   4.0? См. `data/README.md`.
5. Подтвердить у автора, что BSD-текст словаря Лебедева заменил старую
   лицензию «только патчи». Сайт автора не открылся.
6. Нужна ли отдельная атрибуция OpenSubtitles и Twitter, если мы берём только
   частоты wordfreq?

## Не юридические вопросы

- Сколько форм даёт раскрытие ru_RU.aff — измерить на шаге 2. Цель плана —
  1–5 млн; wordfreq добавляет 713 тыс.
- Сборщику нужен читатель parquet (`duckdb` или `pyarrow`) только на этапе
  подготовки текста. В приложение он не попадает.
- Распаковка дампов Stack Exchange требует `7z`.
