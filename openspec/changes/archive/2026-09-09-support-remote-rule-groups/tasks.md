# tasks — поддержка remote-групп Little Snitch

## 1. Helper: разбор модели

- [x] 1.1 `RuleGroupModelParser.parseLittleSnitchGroups`: имя — первое непустое из `userProvidedName` → `customName` → `factoryName`, иначе имя по встроенному `type`, иначе запись пропускается; вид по `type` (`builtin*` → builtin, `loadedFromURL` → remote, всё остальное с именем → local). Проверка: тесты п. 1.5 зелёные
- [x] 1.2 `RuleGroupInfo`: поле `kind: String`; строковые константы `builtin` / `local` / `remote` — в `HelperProtocol.swift` (компилируется в оба таргета), doc-комментарий `listRuleGroups` описывает поле и его необязательность. Проверка: тест кодирования — JSON списка содержит `"kind"` с ожидаемым значением
- [x] 1.3 Парсер возвращает массив в детерминированном порядке: имя по `localizedStandardCompare`, при равных именах — вид в порядке local, builtin, remote; одноимённые записи **не** схлопываются. Проверка: тест «локальная и подписка с одним именем → две записи в фиксированном порядке»
- [x] 1.4 Запасной поиск по форме (`collect`): `nameKeys` дополнены `customName` и `factoryName`. Проверка: тест `RuleGroupModelParserTests` на вложенное дерево, где имя только в `factoryName`
- [x] 1.5 Фикстура `LittleSnitchModelTests` (снимок 2026-09-09, LS 6.5): запись `pykpmH` с `type: loadedFromURL`, `factoryName: "Require VPN Services"`, `factoryDescription: ""`, `loadFromURL: "https://example.com/require-vpn.lsrules"`, `lastSuccessfulUpdate`, `updateInterval`, **без** `isActive`; у локальной группы `ghoGzc` — `type: loadedFromFile`. Тесты: подписка в списке и «выключена»; вид remote; локальная с типом найдена и local; встроенные — builtin; подписка с непустым `customName` — под пользовательским именем; безымянная запись неизвестного типа пропускается (переименовать нынешний тест `skipsUnknownBuiltinType`); внутренние идентификаторы наружу не попадают. Проверка: `xcodebuild test -only-testing:HelperTests` зелёный

## 2. Domain и Application

- [x] 2.1 `Domain/RuleGroup.swift`: `enum RuleGroupKind: String, Hashable, Codable { builtin, local, remote }`; `RuleGroup.kind: RuleGroupKind?` со значением `nil` по умолчанию, существующий `init(name:enabled:)` сохраняется. Проверка: `./Scripts/check-domain-purity.sh` и `DomainTests` зелёные без правок существующих тестов
- [x] 2.2 `SyncRuleGroups.run()`: схлопывание одноимённых с сохранением первой записи; на каждое имя-дубликат — `JournalEvent` вида `.warning` с текстом «одноимённые группы в Little Snitch: «<имя>» — включаются по имени, различить их нельзя». Проверка: тест в `Tests/ApplicationTests`: шлюз вернул «X» local и «X» remote → в `.synced` одна «X» (первая), в журнале одно предупреждение; список без коллизий предупреждений не даёт
- [x] 2.3 `FakeRuleGroupGateway`: способ вернуть произвольный `[RuleGroup]` (с видом и дубликатами) при сохранении нынешнего `init(groups: [String: Bool])`. Проверка: `ApplicationTests` компилируются и зелёные

## 3. Infrastructure: шлюз helper

- [x] 3.1 `HelperRuleGroupGateway`: `HelperRuleGroup.kind: String?`, отображение в `RuleGroupKind?` — отсутствие поля и незнакомая строка дают `nil`; разбор вынесен в функцию, доступную тестам. Проверка: тесты в `Tests/InfrastructureTests` на JSON с `kind`, без `kind` и с незнакомым значением

## 4. Вкладка «Группы»

- [x] 4.1 `RuleGroupsTab` в `SettingsWindow.swift`: для `kind == .remote` подпись «подписка · включена в LS» / «подписка · выключена в LS», для остальных — как сейчас. Проверка: превью `DSRuleGroupRow` с примером подписки; вкладка на целевой машине показывает подпись у «Require VPN Services»

## 5. Документы и спеки

- [x] 5.1 README, раздел «Формат модели Little Snitch 6»: снимок 2026-09-09 (LS 6.5) с записью `loadedFromURL`/`factoryName` и `type: loadedFromFile` у локальной группы; цепочка имени и поле `kind` в описании ответа helper; грабли: «имя подписки меняется на сервере → группа выпадает из маппинга, сработает ошибка «не найдена»» и «одноимённые локальная и подписка — держать имена уникальными». Проверка: `grep -n "https://" README.md` показывает только `example.com` и ссылки на документацию
- [x] 5.2 `SPEC.md` §9: факт «`rulegroup -e/-d` принимает имя подписки (`factoryName`), проверено 2026-09-09 на LS 6.5; подписки лежат в `groups` с `type: loadedFromURL`, флаг `-u` не нужен». Проверка: строка в §9 есть, реальных URL и адресов нет
- [x] 5.3 После реализации — синхронизация дельты в `openspec/specs/rule-group-control/spec.md` (`/opsx:sync`). Проверка: `openspec validate --strict` без ошибок, основная спека содержит сценарии «Подписанная группа в списке» и «Одноимённые группы»

## 6. Проверка и живая приёмка

- [x] 6.1 `xcodegen generate && xcodebuild -project LittleSnitchVPNCompanion.xcodeproj -scheme LittleSnitchVPNCompanion -configuration Debug test` зелёный локально; `./Scripts/check-domain-purity.sh` зелёный; CI «Тесты (macOS 26)» и «Тесты (macOS 15)» зелёные на PR
- [x] 6.2 Сборка установлена в `~/Applications`, helper переустановлен по подсказке приложения (не из DerivedData — ловушка BTM). Вкладка «Группы»: «Require VPN Services» показана с подписью «подписка», состояние совпадает с Little Snitch; в журнале «список групп из LS: 4 шт.»
- [x] 6.3 Реактивный режим, подписка отмечена «включать при утечке»: имитация утечки отладочной настройкой `debugFakeEgressIP` → в журнале «группа «Require VPN Services» включена», записей «не найдена» нет, в Little Snitch группа активна; возврат к Protected → группа выключена
- [x] 6.4 Проверка допущения `customName`: переименовать подписку в Little Snitch → «Обновить список из LS» → строка под новым именем и `rulegroup -d "<новое имя>"` даёт код 0. Если имя не сменилось — снять `export-model`, найти фактический ключ, поправить цепочку п. 1.1 и фикстуру п. 1.5; вернуть подписке прежнее имя
- [x] 6.5 Убрать «Require VPN Services Local» из маппинга, если она была обходным путём (решение пользователя); после «Обновить список из LS» в журнале нет предупреждений об одноимённых группах
