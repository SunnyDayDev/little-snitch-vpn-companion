# Proposal: build-ls-vpn-companion

## Why

Foreign-трафик машины пользователя должен всегда уходить через VPN-цепочку (egress — Cloudflare WARP), но при отвале VPN «запрещённые» приложения (Claude, JetBrains IDE, Android Studio) начинают ходить в сеть напрямую. Существующие механизмы (статус VPN-клиента) врут: «Подключено» не гарантирует реальный путь трафика. Нужен автоматический сторож, который следит за **фактическим egress** и при утечке мгновенно блокирует запрещённые приложения через Little Snitch, а при восстановлении — снимает блок без участия человека.

Полное ТЗ: [SPEC.md](../../../SPEC.md) — согласовано 2026-07-29, все развилки решены (§2 SPEC.md), не перерешивать.

## What Changes

Создаётся с нуля macOS-приложение **Little Snitch VPN Companion** (меню-бар, Swift 6 / SwiftUI, min macOS 26) + привилегированный helper-демон (`SMAppService.daemon` + XPC):

- Трёхслойный детектор фактического egress: постоянная TLS-«растяжка» к маяку Cloudflare, события сетевого пути (`NWPathMonitor`), периодические свежие пробы. Критерий защиты — `warp=on` от маяка, а не статус VPN-клиента.
- РУ-маяк: автоопределение «прямого IP» текущей сети через сервис в зоне `.ru` (уходит мимо VPN благодаря сплиту); denylist `FORBIDDEN_EGRESS` (статические серверы инфраструктуры + динамический прямой IP) сильнее любых прочих признаков.
- Доменная state machine: `Protected` / `Leak` / `Offline` / `Paused`; переход в Leak — только после двух подтверждающих проб; принцип reconcile (приведение фактического состояния групп LS к целевому, не «история включений»).
- Привилегированный helper (root) — единственный компонент, вызывающий `littlesnitch` CLI (`rulegroup -e/-d`, `export-model`); узкий XPC-контракт, валидация клиента по code-signing requirement.
- Эскалация: Leak подтверждён, а helper/LS недоступен → выключить Wi-Fi (`networksetup`, без root); отключаемо.
- Уведомления (`UserNotifications`), журнал событий (JSONL, ротация 7 дней, окно с фильтрами), настройки (`UserDefaults`, окно с вкладками Общие/Детектор/Группы), режим наблюдения (`observeOnly`), автозапуск (login item), онбординг из трёх шагов.
- UI на русском, дизайн-система из `design/app.pen` переносится 1:1 в SwiftUI (токены → атомы → молекулы), Clean Architecture + DDD, Domain и Application покрываются unit-тестами (TDD для state machine).

## Capabilities

### New Capabilities

- `egress-detection`: трёхслойный детектор фактического egress (растяжка, события пути, плановые пробы), классификация ответов маяка, двойное подтверждение утечки, РУ-маяк и denylist `FORBIDDEN_EGRESS` (§4 SPEC.md).
- `state-machine`: доменные состояния Protected/Leak/Offline/Paused, таблица переходов, флаг «helper недоступен», принцип идемпотентного reconcile (§5 SPEC.md).
- `rule-group-control`: управление rule groups Little Snitch через привилегированный helper — XPC-контракт, валидация клиента, вызовы `littlesnitch` CLI, получение списка групп, применение маппинга «состояние → группы» (ФТ-2, ФТ-3, §9, §10.2 SPEC.md).
- `failsafe-escalation`: эскалация при отказе helper/LS (выключение Wi-Fi) и режим наблюдения `observeOnly` (ФТ-9, ФТ-10 SPEC.md).
- `event-journal`: журнал событий — запись, хранение JSONL с ротацией 7 дней, окно с фильтрами, экспорт, очистка (ФТ-6 SPEC.md).
- `user-notifications`: уведомления о переходах состояний и ошибках, две отключаемые категории (ФТ-5 SPEC.md).
- `app-settings`: хранение и UI настроек (Общие/Детектор/Группы), автозапуск через `SMAppService` login item (ФТ-7, ФТ-8 SPEC.md).
- `menu-bar-ui`: меню-бар-приложение без Dock — иконка состояния, поповер со статусом, баннером, инфо-строками и действиями (ФТ-4, §7.1, §7.5 SPEC.md).
- `onboarding`: онбординг первого запуска — установка helper, создание группы в LS, разрешение уведомлений (ФТ-11, §7.6 SPEC.md).

### Modified Capabilities

Нет — проект создаётся с нуля, существующих спеков нет.

## Impact

- **Код**: новый Xcode-проект `LittleSnitchVPNCompanion/` — таргеты App (Presentation + DesignSystem), Application, Domain, Infrastructure, Helper (демон), Tests (DomainTests, ApplicationTests). Структура — §10.3 SPEC.md.
- **Системные зависимости**: только системные фреймворки (Network, URLSession, UserNotifications, ServiceManagement, SwiftUI, os.Logger). Внешних пакетов нет.
- **Внешние сервисы**: маяки Cloudflare (`www.cloudflare.com/cdn-cgi/trace`, `1.1.1.1/cdn-cgi/trace`), РУ-маяки (`yandex.ru/internet/api/v0/ip`, `2ip.ru`) — только чтение, сотни байт трафика.
- **Машина пользователя**: Little Snitch 6 установлен (`/Applications/Little Snitch.app`); helper требует одобрения в System Settings → Login Items; самоподписанный сертификат для подписи обоих таргетов; App Sandbox выключен.
- **Права**: helper работает под root (LaunchDaemon) — единственная точка вызова `littlesnitch` CLI; эскалация Wi-Fi root не требует.
