/// Настройки приложения (ФТ-7) с дефолтами §13 SPEC.md. Динамический прямой
/// РУ-IP сюда не входит — он живёт только в рантайме координатора.
struct AppSettings: Hashable, Sendable, Codable {
    var launchAtLogin = true
    var monitoringEnabled = true
    var observeOnly = false
    var escalationEnabled = true
    var notifyTransitions = true
    var notifyErrors = true

    var heartbeatSeconds = 15.0
    var probeSeconds = 60.0
    var probeTimeoutSeconds = 6.0
    /// Задержка подтверждающей пробы (§4.3: 2–3 с).
    var leakConfirmationSeconds = 2.5
    /// Схлопывание шквала событий сетевого пути (§4.2).
    var pathDebounceSeconds = 0.3

    /// Детекторы (D10 design.md): у каждого свои маяк, путь, правила, режим
    /// защиты и группы. Пустой массив допустим — мониторинг работает
    /// вхолостую.
    var detectors: [DetectorConfig] = [.primary()]

    var ruBeaconURL = "https://yandex.ru/internet/api/v0/ip"
    var ruBeaconFallbackURL = "https://2ip.ru"
    var ruBeaconRefreshSeconds = 300.0

    /// Скрытые debug-рычаги для приёмки (§14, сценарии 2–3 и 13–14).
    /// Глобальные: действуют на все детекторы.
    var debugIgnoreWarp = false
    var debugFakeEgressIP: String?

    static let defaultLeakGroupName = "VPN down"

    func detector(_ id: DetectorID) -> DetectorConfig? {
        detectors.first { $0.id == id }
    }

    var enabledDetectors: [DetectorConfig] { detectors.filter(\.isEnabled) }

    /// Включённые детекторы в строгом режиме: их группы закрываются на сне,
    /// паузе и завершении и уходят в failsafe helper.
    var strictDetectors: [DetectorConfig] {
        enabledDetectors.filter { $0.protectionMode == .strict }
    }

    /// Объединение групп строгих детекторов (D8 design.md).
    var failsafeGroups: [String] {
        Array(Set(strictDetectors.flatMap(\.groups))).sorted()
    }

    /// Строгий режим действует: есть хоть один включённый строгий детектор,
    /// и `observeOnly` его не перекрывает (ФТ-10 побеждает).
    var strictActive: Bool { !strictDetectors.isEmpty && !observeOnly }

    /// Failsafe-конфигурация helper: контракт прежний — плоский список групп,
    /// о детекторах helper не знает.
    var failsafeConfig: FailsafeConfig {
        FailsafeConfig(strictActive: strictActive, groups: failsafeGroups)
    }

    /// Критерии классификации детектора. Динамический прямой РУ-IP
    /// подставляет координатор; debug-рычаг глобальный.
    func criteria(for detector: DetectorConfig, directRuIP: IPAddress?) -> EgressCriteria {
        detector.criteria(directRuIP: directRuIP, ignoreWarpForDebug: debugIgnoreWarp)
    }

    /// Детекторы, чей маппинг содержит группу: уведомления и журнал о
    /// несуществующей группе (включённые), подпись «также в …» (все).
    func owners(of group: String,
                excluding id: DetectorID? = nil,
                enabledOnly: Bool = true) -> [DetectorConfig] {
        (enabledOnly ? enabledDetectors : detectors)
            .filter { $0.id != id && $0.groups.contains(group) }
    }
}
