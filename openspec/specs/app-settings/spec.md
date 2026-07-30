# app-settings

## Purpose

Хранение и редактирование настроек приложения: окно с вкладками Общие/Детектор/Группы, персистентность в UserDefaults, значения по умолчанию и автозапуск через login item.

## Requirements

### Requirement: Персистентные настройки

Настройки SHALL храниться в `UserDefaults` с ключами: `launchAtLogin`, `monitoringEnabled`, `observeOnly`, `escalationEnabled`, `notifyTransitions`, `notifyErrors`, `heartbeatSeconds`, `probeSeconds`, `probeTimeoutSeconds`, `expectedIPs` ([String]), `leakGroups` ([String]), `forbiddenEgressIPs` ([String], статическая часть denylist), `ruBeaconURL`, `ruBeaconRefreshSeconds`. Динамический прямой РУ-IP SHALL NOT сохраняться в defaults (runtime-значение, сбрасывается при смене сети).

#### Scenario: Настройка переживает перезапуск

- **WHEN** пользователь изменил `probeSeconds` и перезапустил приложение
- **THEN** применяется сохранённое значение

#### Scenario: Прямой IP не персистится

- **WHEN** приложение перезапущено
- **THEN** динамический прямой РУ-IP отсутствует до нового ответа РУ-маяка

### Requirement: Значения по умолчанию

При первом запуске SHALL действовать конфигурация: `monitoringEnabled=true`, `observeOnly=false`, `escalationEnabled=true`, `launchAtLogin=true` (после онбординга), `heartbeatSeconds=15`, `probeSeconds=60`, `probeTimeoutSeconds=6`, подтверждение утечки 2 пробы / 2.5 с, `expectedIPs=[]`, `leakGroups=["VPN down"]` (если группа существует в LS; иначе пусто + подсказка в UI), обе категории уведомлений включены, `ruBeaconURL="https://yandex.ru/internet/api/v0/ip"`, `ruBeaconFallbackURL="https://2ip.ru"`, `ruBeaconRefreshSeconds=300`, `forbiddenEgressIPs` — предзаполненный список серверов инфраструктуры из §13 SPEC.md.

#### Scenario: Дефолтная группа отсутствует в LS

- **WHEN** при первом запуске группа «VPN down» не существует в Little Snitch
- **THEN** `leakGroups` остаётся пустым и в UI показывается подсказка о создании группы

### Requirement: Окно настроек с вкладками

Приложение SHALL предоставлять окно настроек с вкладками Общие / Детектор / Группы (состав секций и контролов — §7.2–7.4 SPEC.md). Изменения SHALL применяться к работающему детектору без перезапуска приложения.

#### Scenario: Переключение мониторинга

- **WHEN** пользователь выключает тумблер «Мониторинг» на вкладке Общие
- **THEN** детектор останавливается без перезапуска приложения

#### Scenario: Редактирование запрещённого egress

- **WHEN** пользователь через редактор списка меняет статический список `FORBIDDEN_EGRESS`
- **THEN** новый список сохраняется и учитывается ближайшей пробой

### Requirement: Автозапуск

Приложение SHALL регистрироваться как login item через `SMAppService` с тумблером «Запускать при входе в систему» в настройках; автозапуск включается в онбординге.

#### Scenario: Автозапуск после перезагрузки

- **WHEN** `launchAtLogin=true` и машина перезагружена
- **THEN** приложение автоматически запускается при входе в систему
