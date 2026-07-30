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

    var expectedIPs: [String] = []
    var leakGroups: [String] = []
    /// Статическая часть `FORBIDDEN_EGRESS` — серверы инфраструктуры.
    /// Пуст по умолчанию: выходные узлы у каждого свои, а приложение
    /// раздаётся другим людям (отклонение от §13 SPEC.md — осознанное).
    var forbiddenEgressIPs: [String] = []

    var ruBeaconURL = "https://yandex.ru/internet/api/v0/ip"
    var ruBeaconFallbackURL = "https://2ip.ru"
    var ruBeaconRefreshSeconds = 300.0

    /// Скрытые debug-рычаги для приёмки (§14, сценарии 2–3 и 13–14).
    var debugIgnoreWarp = false
    var debugFakeEgressIP: String?

    static let defaultLeakGroupName = "VPN down"

    var mapping: RuleGroupMapping { RuleGroupMapping(leakGroups: leakGroups) }

    /// Критерии классификации, собранные из настроек. Динамический прямой
    /// РУ-IP подставляет координатор.
    func criteria(directRuIP: IPAddress?) -> EgressCriteria {
        EgressCriteria(
            expectedIPs: Set(expectedIPs.compactMap(IPAddress.init)),
            forbiddenServers: Set(forbiddenEgressIPs.compactMap(IPAddress.init)),
            directRuIP: directRuIP,
            ignoreWarpForDebug: debugIgnoreWarp)
    }
}
