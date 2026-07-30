# failsafe-escalation — Delta Spec

## Purpose

Отказоустойчивость: эскалация при подтверждённой утечке с недоступным helper/Little Snitch (выключение Wi-Fi) и режим наблюдения `observeOnly` для безопасной обкатки без реальных действий.

## ADDED Requirements

### Requirement: Эскалация выключением Wi-Fi

Если Leak подтверждён, а helper недоступен или CLI вернул ошибку, система SHALL выключить Wi-Fi через `networksetup -setairportpower <dev> off` (root не требуется; Wi-Fi-устройство определяется через `networksetup -listallhardwareports`) и отправить уведомление с объяснением. Эскалация SHALL быть включена по умолчанию и отключаема настройкой `escalationEnabled`.

#### Scenario: Helper недоступен при подтверждённой утечке

- **WHEN** состояние Leak подтверждено, эскалация включена, а вызов helper завершился ошибкой
- **THEN** Wi-Fi выключается и отправляется уведомление с объяснением причины

#### Scenario: Эскалация отключена

- **WHEN** состояние Leak подтверждено, helper недоступен, но `escalationEnabled=false`
- **THEN** Wi-Fi не трогается; отправляется уведомление об ошибке helper

#### Scenario: Определение Wi-Fi-устройства

- **WHEN** требуется выключить Wi-Fi
- **THEN** имя устройства определяется динамически из `networksetup -listallhardwareports`, а не захардкожено

### Requirement: Режим наблюдения

При включённом `observeOnly` система SHALL продолжать работу детектора, журнала и уведомлений, но SHALL NOT изменять rule groups Little Snitch и SHALL NOT выключать Wi-Fi.

#### Scenario: Утечка в режиме наблюдения

- **WHEN** `observeOnly=true` и зафиксирован переход в Leak
- **THEN** отправляется уведомление и пишется журнал, но группы LS не включаются

#### Scenario: Отказ helper в режиме наблюдения

- **WHEN** `observeOnly=true`, состояние Leak, helper недоступен
- **THEN** Wi-Fi не выключается
