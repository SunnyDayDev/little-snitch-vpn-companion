# tasks — строгий режим защиты

## 1. Domain: режим как параметр политики

- [x] 1.1 `ProtectionMode` (reactive/strict) в Domain; `EgressState` + кейс `checking`
- [x] 1.2 `LeakPolicy.targetEnabledGroups(for:mode:)` и `plan(for:mapping:actual:mode:)`: strict → всё, кроме Protected, закрывает; reactive — текущее поведение; тесты LeakPolicy по обоим режимам
- [x] 1.3 `StateMachine.handle(event:mode:)`: событие `.pathDown`; режимозависимые строки (`started`, `pathChanged`, `userPaused`, `userResumed`, offline-вердикт); порядок эффектов «закрыть до пробы»; тесты машины — существующие как ветка reactive + зеркальная strict-матрица (каждая режимозависимая строка в обоих режимах, вход в checking только в strict)

## 2. Application: координатор

- [x] 2.1 `AppSettings.protectionMode` + ключ в `DefaultsSettingsStore` (register/load/save, фолбэк reactive на нераспознанное значение); `TestData.settings(mode:)`
- [x] 2.2 Координатор различает `isSatisfied`: `pathDown` без debounce + инкремент `probeGeneration` (инвалидация проб в полёте); `pathChanged` в strict — закрывающий reconcile до debounce; тесты: гонка «подвешенная проба vs pathDown» (расширить `FakeBeacon` continuation-подвесом), немедленность закрытия
- [x] 2.3 `ApplyPolicy.run(state:settings:)` учитывает режим; переходная операция для смены режима на лету (strict→reactive: открыть, если не Leak); тесты ApplyPolicy
- [x] 2.4 `pause()`/тумблер мониторинга: в strict закрывающий reconcile ДО `isActive=false` и остановки слоёв; `resume()` в strict → checking + открытие только по Protected; тесты координатора (включая «stop/Cmd-Q закрывает» — пересмотр теста `stopPreventsGroupChanges`)
- [x] 2.5 Смена режима в `AppModel.update()`: журнал, переходный reconcile, синхронизация failsafe-конфига helper; тесты
- [x] 2.6 Эскалация: подтвердить тестами, что провал закрытия при Offline/Checking НЕ эскалирует (Wi-Fi off только при Leak); observeOnly поверх strict (журнал «закрыл бы», группы не тронуты)

## 3. App: завершение и UI

- [x] 3.1 `AppDelegate` (`@NSApplicationDelegateAdaptor`): `applicationShouldTerminate` → `.terminateLater` → закрывающий reconcile в strict (таймаут ~3 с) → reply
- [x] 3.2 Настройки → Общие: карточка «Режим защиты» (сегмент-контрол «Блокировать при утечке» / «Открывать только при VPN», поясняющая подпись; предупреждение при observeOnly+strict)
- [x] 3.3 Поповер: заголовок/подзаголовок/warn-баннеры для Checking и Offline-strict, Paused-strict; строка «Группы LS» warn-цветом при «включены без утечки»
- [x] 3.4 `DSStatusIcon` + иконка меню-бара: глиф Checking, warn-акценты (Checking, Paused, Offline-strict); монохром Protected и Offline-reactive
- [x] 3.5 Онбординг: предупреждение на шаге 2 (не включать браузер и VPN-клиент в группу); та же подсказка на вкладке «Группы»
- [x] 3.6 Журнал: переходы с участием Checking рендерятся и фильтруются корректно (цвет/категория)

## 4. Helper: failsafe

- [x] 4.1 XPC-операция `setFailsafe(config)` в протоколе + gateway; персист конфига в `/Library/Application Support/<label>/failsafe.json`; чтение при старте helper; синхронизация из приложения (старт, смена режима/групп/observeOnly); тесты парсинга/персиста
- [x] 4.2 Supervision: invalidation-обработчики входящих соединений + счётчик живых клиентов + таймер (тестируемый тип поверх абстракции часов); presence-соединение на стороне приложения с немедленным реконнектом; порядок «strictActive=false перед переустановкой helper»
- [x] 4.3 Ручная приёмка dead-man's switch: kill -9 приложения при Protected/strict → группы включаются за ≤ таймаут супервизии

## 5. Загрузка ОС (после спайка)

- [x] 5.1 Спайк на живой машине: SMAppService + RunAtLoad (UX одобрения), доступность `littlesnitch` CLI на раннем этапе загрузки; зафиксировать результат в design.md
- [x] 5.2 По результатам спайка: RunAtLoad в plist + закрытие групп при старте helper с retry/backoff до поднятия listener; либо задокументированный фолбэк без эшелона 4 (§15)

## 6. Документы и макеты

- [x] 6.1 SPEC.md: §1 (следствия по режимам), §3 (термины: режим защиты, Checking, закрыто/открыто), §5 (таблица с колонками режимов + pathDown), ФТ-2/ФТ-5/ФТ-7/ФТ-9/ФТ-10, §7.1–7.5 (баннеры, карточка режима, иконки), §10.2 (XPC-контракт + failsafe), §13 (дефолты: protectionMode, supervisionTimeout), §14 (парные ожидания сценариев 4/7/9 + новые: Cmd-Q, kill -9, смена сети, старт без VPN, загрузка ОС, captive portal), §15 (риск самозапирания + ручной выход средствами LS)
- [x] 6.2 Макеты `design/app.pen` (light+dark): Поповер — Проверка (strict), Поповер — Офлайн (reactive и strict), Настройки — Общие с карточкой режима, ряд иконок с пятым глифом; синхронизировать файл в ветку (сделано на стадии propose)
- [x] 6.3 Прогон всех приёмочных сценариев §14 в обоих режимах на живой машине; зелёный CI
