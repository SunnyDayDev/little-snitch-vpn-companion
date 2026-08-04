# Little Snitch VPN Companion

[![CI](https://github.com/SunnyDayDev/little-snitch-vpn-companion/actions/workflows/ci.yml/badge.svg)](https://github.com/SunnyDayDev/little-snitch-vpn-companion/actions/workflows/ci.yml)

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_128.png" align="right" width="110" alt="Иконка приложения">

Меню-бар-приложение для macOS, которое следит за **фактическим egress-IP** машины и в
момент, когда трафик пошёл мимо VPN, включает запрещающие rule groups в
[Little Snitch](https://www.obdev.at/products/littlesnitch/). Туннель восстановился —
выключает их автоматически.

*English TL;DR: a macOS menu bar app that watches the machine's actual egress IP and,
the moment traffic leaks past your VPN, flips deny-rule groups in Little Snitch — then
flips them back when the tunnel recovers. Detection is beacon-based (Cloudflare
`cdn-cgi/trace` + a local-country IP beacon), enforcement goes through a tiny root
helper that only knows three XPC operations. Docs and UI are in Russian.*

## Зачем

VPN-клиент упал, переподключается или «тихо» перестал держать маршрут — а трафик
продолжает идти, уже напрямую через провайдера. Kill-switch в клиенте есть не всегда,
а главное — он доверяет *самому клиенту*. Это приложение не доверяет никому: оно
регулярно спрашивает у внешних маяков, **кто на самом деле видит ваш трафик снаружи**,
и реагирует на факт, а не на статус в чужом UI.

Реакция — штатный механизм Little Snitch: rule groups с запрещающими правилами,
которые companion включает при утечке и выключает при восстановлении.

## Как это работает

1. **Проба egress.** Раз в 60 с (и по каждому событию сетевого пути) приложение
   опрашивает маяк Cloudflare (`cdn-cgi/trace`): оттуда приходят фактический
   egress-IP, флаг `warp=on` и дата-центр.
2. **Прямой IP для сравнения.** Отдельный РУ-маяк (yandex, резерв — 2ip) сообщает,
   какой IP выдал провайдер напрямую, — это динамическая часть denylist.
3. **Классификация.** `warp=on` или egress из allowlist `expectedIPs` → **Protected**.
   Egress совпал с адресом из `forbiddenEgressIPs` (ваши же VPN-серверы) → **Leak**
   «цепочка вышла напрямую с сервера». Egress совпал с прямым IP провайдера → **Leak**
   «полный обход VPN». Маяки недоступны → **Offline** (это не утечка).
4. **Растяжка (tripwire).** Постоянное TCP-соединение с heartbeat 15 с замечает обрыв
   туннеля за секунды — не дожидаясь следующей пробы.
5. **Реакция.** Утечка подтверждается второй пробой (~2.5 с), затем привилегированный
   helper включает назначенные rule groups (`littlesnitch rulegroup -e`). Состояние
   восстановилось — группы выключаются сами. Обо всём — уведомление и запись в журнал.
6. **Эскалация.** Если утечка подтверждена, а helper или CLI недоступны, приложение
   выключает Wi-Fi (`networksetup -setairportpower off`) — лучше без сети, чем напрямую.
7. **Режимы защиты.** Реактивный (по умолчанию): группы включаются только при
   доказанной утечке. Строгий (fail-closed): открыто **только** при доказанном VPN —
   всё неопределённое закрывает. Эшелоны закрытия строгого режима: старт до первого
   вердикта, пропажа сети, пауза, ⌘Q, крэш приложения (dead-man's switch в helper),
   загрузка ОС до старта приложения и **уход машины в сон** — сон не гасит сеть
   (TCPKeepAlive), поэтому группы включаются до засыпания, а после пробуждения
   открываются только по свежему вердикту Protected.

Состояния Protected / Leak / Offline / Checking / Paused живут в state machine на чистом
Swift без Apple-фреймворков; таблица переходов из ТЗ покрыта тестами построчно.
Полное ТЗ: [SPEC.md](SPEC.md), артефакты разработки:
`openspec/changes/archive/2026-07-30-build-ls-vpn-companion/`.

## Что понадобится

**Для запуска:**

- macOS 15.7+ (поддерживаемый диапазон — 15.7–26.x)
- Little Snitch 6 в `/Applications/Little Snitch.app`
- rule group в Little Snitch с запрещающими правилами (по умолчанию ожидается имя
  **«VPN down»**; любое другое задаётся в настройках)

**Для сборки** — дополнительно:

- Xcode 26.x. На Sequoia ставятся только 26.0–26.3 (им нужна macOS 15.6+), а Xcode 26.4
  и новее требуют macOS 26.2+. Сборка идёт против SDK 26 при deployment target 15.7 —
  штатная схема, отдельно ничего настраивать не нужно
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — проект
  генерируется из `project.yml`, сам `.xcodeproj` в git не хранится

Проверено: сборка и тесты на macOS 26.5.2 (Xcode 26.6, Apple Silicon) и в CI на образе
macOS 15.7 с Xcode 26.x; живая эксплуатация — на 26.x (Apple Silicon) и на 15.7.8 (Intel).

Артефакт универсальный (`arm64` + `x86_64`), поэтому Intel-машине собственный Xcode не
нужен: приложение собирается на Apple Silicon и переносится готовым бандлом — см.
«[Перенос на другую машину](#перенос-на-другую-машину)».

## Сборка и запуск

```bash
xcodegen generate && xcodebuild -project LittleSnitchVPNCompanion.xcodeproj -scheme LittleSnitchVPNCompanion -configuration Debug build
```

```bash
open ~/Library/Developer/Xcode/DerivedData/LittleSnitchVPNCompanion-*/Build/Products/Debug/"Little Snitch VPN Companion.app"
```

Приложение живёт только в строке меню (`LSUIElement`), в Dock не появляется.

### Установка

Для повседневной работы приложение должно лежать в `~/Applications`, а не в
каталоге сборки: путь внутри DerivedData меняется при смене конфигурации, а
System Settings — песочное приложение и не может прочитать оттуда бандл, из-за
чего в «Объектах входа» вместо иконки виден серый плейсхолдер.

```bash
./Scripts/install.sh
```

Скрипт собирает Release, копирует в `~/Applications`, обновляет реестр
LaunchServices и запускает установленную копию. `/Applications` требует прав
администратора; если аккаунт обычный — `~/Applications` штатная замена.

После первой установки (и после каждого обновления, меняющего helper) демон
нужно перерегистрировать: **Настройки → Общие → «Переустановить…»**, затем
одобрить объект входа.

### Перенос на другую машину

Xcode на целевой машине не нужен: артефакт универсальный (`arm64` + `x86_64`), и
Intel-машина запускает его нативно. Для Intel это единственный путь — Xcode 26 в
App Store отдаётся сборкой под Apple Silicon.

Сертификат подписи переносить тоже не нужно: он встроен в подпись, а helper строит
XPC-requirement из собственной подписи — «клиент подписан тем же сертификатом, что и я».
Совпадение проверяется внутри бандла, связка ключей целевой машины ни при чём.

Собрать Release и упаковать (`ditto` сохраняет подпись и обе архитектуры):

```bash
xcodebuild -project LittleSnitchVPNCompanion.xcodeproj -scheme LittleSnitchVPNCompanion -configuration Release build
```

```bash
ditto -c -k --sequesterRsrc --keepParent ~/Library/Developer/Xcode/DerivedData/LittleSnitchVPNCompanion-*/Build/Products/Release/"Little Snitch VPN Companion.app" ~/Downloads/LSVPNCompanion.zip
```

На целевой машине распаковывать **сразу в `~/Applications`** — запуск из `~/Downloads`
привяжет демона к этому пути в базе BTM (см. «Грабли», п. 1):

```bash
ditto -x -k ~/Downloads/LSVPNCompanion.zip ~/Applications
```

```bash
xattr -dr com.apple.quarantine ~/Applications/"Little Snitch VPN Companion.app"
```

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f -R -trusted ~/Applications/"Little Snitch VPN Companion.app"
```

Приложение не нотаризовано. Если архив приехал через AirDrop, браузер или почту, на нём
стоит флаг карантина — снимает его команда `xattr` выше. Без неё первый запуск отклоняется,
и в Sequoia обход через Control-click → «Открыть» больше не работает: остаётся
**Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»**.
Передача через `scp`, `rsync` или внешний диск карантина не ставит вовсе.

Дальше — как при обычной установке: открыть, пройти онбординг, одобрить объект входа.
Little Snitch, его rule group и доступ для CLI на целевой машине настраиваются отдельно.

## Настройка под себя

Все адреса в репозитории — заполнители из документационных диапазонов RFC 5737;
свои значения вносятся в настройках приложения:

- **`forbiddenEgressIPs`** — IP ваших собственных VPN-серверов. Если egress совпал с
  одним из них, значит цепочка «схлопнулась» и трафик выходит напрямую с сервера.
- **`expectedIPs`** — allowlist выходных адресов. Детектор считает состояние защищённым
  при `warp=on` (Cloudflare WARP как последнее звено) **или** при egress из этого
  списка — если ваша цепочка не через WARP, просто внесите сюда свои выходные IP.
- **Маппинг групп** — какие rule groups включать при утечке.
- В самом Little Snitch включите доступ для CLI: **Little Snitch → Настройки →
  Безопасность** (см. «Грабли», п. 2).

## Тесты

```bash
xcodebuild -project LittleSnitchVPNCompanion.xcodeproj -scheme LittleSnitchVPNCompanion -configuration Debug test
```

130 тестов в четырёх бандлах: `DomainTests` (state machine и классификатор — таблицы §4.1
и §5 SPEC.md покрыты построчно), `ApplicationTests` (use cases на фейках портов),
`HelperTests` (толерантный разбор модели LS), `InfrastructureTests` (журнал, настройки,
парсеры маяка и `networksetup`).

Проверка чистоты доменного слоя (Domain не должен импортировать Apple-фреймворки):

```bash
./Scripts/check-domain-purity.sh
```

### Живые проверки детектора

Обе утилиты собираются из доменного слоя и трогают сеть только на чтение
(два GET по сотне байт).

```bash
swiftc -swift-version 6 Domain/*.swift Scripts/live-check.swift -o /tmp/live-check && /tmp/live-check
```

Печатает ответ маяка, прямой IP от РУ-маяка, вердикт по фактическому egress и
контрольные подмены debug-сценариев §14 (2, 13, 14).

```bash
swiftc -swift-version 6 Domain/*.swift Application/Ports.swift Application/AppSettings.swift Infrastructure/TripwireConnection.swift Infrastructure/SystemPathMonitor.swift Scripts/live-tripwire.swift -o /tmp/live-tripwire && /tmp/live-tripwire
```

Держит растяжку 14 с с heartbeat 3 с и печатает обрывы и события сетевого пути.

## Архитектура

```
App/            Presentation: SwiftUI-экраны, AppModel, composition root
App/DesignSystem/  токены → атомы → молекулы (§8 SPEC.md)
Application/    use cases и порты (протоколы)
Domain/         чистый Swift без Apple-фреймворков: state machine, классификатор, политика
Infrastructure/ проберы, растяжка, XPC-клиент, журнал, настройки, Wi-Fi
Helper/         привилегированный демон (root) + XPC-контракт
Tests/          DomainTests, ApplicationTests, HelperTests, InfrastructureTests
Scripts/        живые проверки детектора, установка, проверка чистоты Domain
```

Зависимости идут только внутрь: `Domain` не знает ни о чём, `Application` — только о
`Domain` и своих портах, `Infrastructure` и `App` подставляют реализации в
[App/CompositionRoot.swift](App/CompositionRoot.swift).

### Привилегированный helper

Единственный компонент с правами root: только он вызывает `littlesnitch` CLI
(`rulegroup -e/-d`, `export-model`). Контракт — три XPC-операции, произвольные команды
не проходят по построению. Helper валидирует подключающегося XPC-клиента по
code-signing requirement и отклоняет посторонних (в том числе сам Little Snitch).

Установка — шаг 1 онбординга (кнопка «Установить helper…») или тумблер в настройках.
После `SMAppService.daemon(...).register()` macOS требует одобрения в
**System Settings → Основные → Объекты входа**. Пока helper не одобрен, приложение
работает в режиме деградации: детектор и журнал живут, группы LS не переключаются,
в поповере горит строка с диагнозом.

### Подпись

Проект подписывается самоподписанным сертификатом (см.
[Signing.xcconfig](Signing.xcconfig) — там же пошаговая инструкция, как создать свой
в Keychain Access). Тогда XPC-requirement строится строго: `identifier
"dev.sunnyday.lsvpncompanion" and certificate leaf = H"<sha1 сертификата>"` — helper
пускает только приложение, подписанное тем же сертификатом.

**Важно: `ENABLE_DEBUG_DYLIB = NO` обязателен** и уже прописан. Hardened Runtime
включает library validation, а у самоподписанного сертификата нет Team ID, поэтому
отладочная прослойка Xcode (`<продукт>.debug.dylib`, по умолчанию включена) не проходит
проверку и приложение падает при запуске с `Library not loaded … different Team IDs`.
С ad-hoc подписью дефект не проявляется — только с настоящим сертификатом.

Без сертификата (ad-hoc, `CODE_SIGN_IDENTITY = -`) собрать и запустить тоже можно, но
**XPC-валидация клиента работает в ослабленном режиме**: у ad-hoc подписи нет устойчивой
identity, поэтому helper проверяет только `identifier` и пишет предупреждение в лог.

## Грабли, собранные при разработке

Всё ниже проверено на живой машине — сэкономит вам вечер.

### 1. Пересборка helper требует перерегистрации демона

launchd привязывает демон к его подписи на момент регистрации (launch constraint,
LWCR). Пока меняется только код приложения, helper не перекомпилируется и всё работает.
Но как только меняются исходники в `Helper/`, бинарь становится другим и launchd
отказывается его запускать — в `launchctl print system/dev.sunnyday.lsvpncompanion.helper`
это видно как `last exit code = 78: EX_CONFIG` и `needs LWCR update`, а приложение
показывает «helper не ответил за 6 с».

Обычно лечится **Настройки → Общие → «Переустановить…»** (приложение делает то же само,
если демон зарегистрирован, но не отвечает, — не чаще раза за запуск); macOS может
попросить заново одобрить объект входа.

Если job застрял окончательно (`job state = spawn failed`), launchd держит устаревший
constraint, и ни `register()`, ни `unregister()`+`register()` из приложения его не
обновляют. Снять запись может только root:

```bash
sudo launchctl bootout system/dev.sunnyday.lsvpncompanion.helper
```

После этого приложение видит `notRegistered` и регистрирует демон заново само.

Проверенные тупики, чтобы не повторять: самозавершение helper при смене бинаря
(launchd всё равно не запускает заменённый бинарь под старой регистрацией) и
перерегистрация из приложения (constraint остаётся прежним).

### 2. Little Snitch должен разрешить доступ своему CLI

Отдельный тумблер внутри самого Little Snitch. Пока он выключен, `littlesnitch`
даже под root отвечает:

```
Error: command line tool is not authorized to make changes.
Please enable access in Little Snitch.app > Preferences > Security.
```

Включается в **Little Snitch → Настройки → Безопасность**. Приложение распознаёт
именно эту ошибку и показывает отдельную подсказку с кнопкой «Открыть Little Snitch…».
А без root `littlesnitch` печатает `littlesnitch must be run as root!` и выходит
с кодом 14 — поэтому CLI и живёт в helper.

### 3. Формат модели Little Snitch 6

Структура `export-model` не документирована; снята с живой машины 2026-07-30 и
закреплена тестами (`Tests/HelperTests/LittleSnitchModelTests.swift`):

```json
"groups": {
  "aaaaac": {"type": "builtinMacOSServices", "isActive": true},
  "aaaaad": {"type": "builtinICloudServices", "isActive": true},
  "ghoGzc": {"userProvidedName": "Require VPN Services", "creationDate": "…"}
}
```

- имя пользовательской группы — в `userProvidedName`; у встроенных имени нет вовсе,
  их опознаёт `type` (`builtinMacOSServices` → «macOS Services»);
- `isActive` присутствует только у включённых групп: **отсутствие ключа означает
  «выключена»**;
- ключи словаря (`aaaaac`) — внутренние идентификаторы LS, наружу они не отдаются.

Если формат сменится с версией LS, парсер переходит к общему поиску по форме объекта,
а при неудаче сообщает в журнал фактические ключи и форму — по ним разбор дописывается
без гадания.

### 4. Мелочи эксплуатации helper

- Версия helper включает отпечаток его бинаря, поэтому приложение замечает устаревший
  демон. Путь к своему бинарю helper берёт через `_NSGetExecutablePath`: `argv[0]` у
  launchd-демона путём не является, а `Bundle.main` внутри бандла приложения указывает
  на бинарь приложения — оба варианта давали версию `build unknown`.
- `SMAppService.unregister()` завершается асинхронно: вызвать `register()` сразу
  нельзя — снятие регистрации отменит её. `HelperInstaller.reinstall()` дожидается
  фактического `.notRegistered`.
- XPC-вызовы ограничены таймаутом 6 с: зарегистрированный, но не одобренный демон
  не отвечает и не сообщает об ошибке — без таймаута запрос висел бы молча.
- Если регистрация слетела, а онбординг пройден, приложение восстанавливает её само.

## Скрытые debug-рычаги (приёмка §14)

```bash
defaults write dev.sunnyday.lsvpncompanion debugIgnoreWarp -bool true
```

Игнорировать `warp=on` — приложение должно за ≤5 с зафиксировать Leak и включить
группы, а при снятии флага само вернуться в Protected.

```bash
defaults write dev.sunnyday.lsvpncompanion debugFakeEgressIP -string "198.51.100.10"
```

Подменить egress маяка: адрес из вашего `forbiddenEgressIPs` даёт диагноз «цепочка
вышла напрямую с сервера», текущий прямой РУ-IP — «полный обход VPN».

Снять рычаги:

```bash
defaults delete dev.sunnyday.lsvpncompanion debugIgnoreWarp; defaults delete dev.sunnyday.lsvpncompanion debugFakeEgressIP
```

Изменения подхватываются на следующей пробе — перезапуск не нужен: проберы читают
настройки в момент запроса.

## Журнал

`~/Library/Application Support/LittleSnitchVPNCompanion/journal.jsonl` — JSONL, ротация
7 дней. Окно журнала (поповер → «Журнал…») даёт фильтры Все/Переходы/Действия/Ошибки,
экспорт в текст и очистку.

## Иконка

Нарисована в `design/app.pen` (лист «Иконка приложения») и обыгрывает иконку Little
Snitch: тот же синий градиентный квадрат и белая «синька»-разметка вокруг центральной
фигуры, но вместо ротора — щит. Артворк собственный: PNG Objective Development не
используются. Для 16–64 px лежит упрощённый вариант того же мотива — тонкая разметка
на таком размере превращается в грязь.

## Статус и ограничения

- Диапазон macOS — 15.7–26.x, обе границы проверены живой эксплуатацией: macOS 26.x на
  Apple Silicon и macOS 15.7.8 (Sequoia) на Intel, где приложение работает несколько дней
  без отличий в поведении. Сборка и тесты на обеих границах прогоняются в CI.
- Заточено под конкретный сценарий: цепочка с Cloudflare WARP последним звеном и
  российский провайдер как «прямой» путь. Другие конфигурации работают через
  `expectedIPs`, но именно WARP-эвристика (`warp=on`) — основной сигнал «защищён».
- РУ-маяки (`yandex.ru`, `2ip.ru`) имеют смысл, когда «прямой» выход — в России;
  URL обоих маяков меняются в настройках.
- Little Snitch — не песочница: rule groups фильтруют новые соединения, но уже
  установленные могут дожить до своего таймаута.

## Контрибуция

Правила — в [CONTRIBUTING.md](CONTRIBUTING.md). Главное: `main` принимает только PR
с зелёным CI, а любое изменение логики идёт через Spec-Driven Development
(OpenSpec) и обновляет спеки в `openspec/specs/`.

## Лицензия

[MIT](LICENSE). Little Snitch — продукт [Objective Development](https://www.obdev.at/);
этот проект с ними не аффилирован.
