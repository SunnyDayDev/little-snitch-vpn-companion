/// Порты Application-слоя (§10.1 SPEC.md). Всё, что умеет сеть, диск,
/// уведомления и вызовы helper, прячется за этими протоколами — благодаря
/// чему use cases тестируются на фейках без единого системного вызова.

/// Результат обращения к foreign-маяку: либо сырое тело для классификации,
/// либо причина, по которой ответа нет.
enum BeaconFetch: Hashable, Sendable {
    case body(String)
    case offline(OfflineReason)
}

protocol BeaconProbing: Sendable {
    /// Свежая проба новым соединением (ephemeral): основной маяк, при сбое — резервный.
    func fetchTrace(timeout: Double) async -> BeaconFetch
}

protocol DirectIPProbing: Sendable {
    /// Прямой IP текущей сети от РУ-маяка. `nil` — сервис недоступен или ответ
    /// не является IP-адресом.
    func fetchDirectIP(timeout: Double) async -> IPAddress?
}

protocol TripwireMonitoring: Sendable {
    /// Постоянное TLS-соединение с heartbeat. `onBreak` вызывается при обрыве
    /// или истечении дедлайна чтения.
    func start(heartbeatSeconds: Double, onBreak: @escaping @Sendable () -> Void) async
    func stop() async
    /// Смена сети — повод переустановиться немедленно, не досиживая backoff.
    func networkPathChanged() async
}

extension TripwireMonitoring {
    func networkPathChanged() async {}
}

protocol PathMonitoring: Sendable {
    /// Изменения сетевого пути. Debounce делает вызывающий.
    func start(onChange: @escaping @Sendable (NetworkPathInfo) -> Void) async
    func stop() async
}

protocol PowerMonitoring: Sendable {
    /// События системного питания (§4.2, слой 4). `onWillSleep` асинхронный
    /// намеренно: его возврат — сигнал «закрытие выполнено», и только после
    /// него (или по истечении собственного бюджета) инфраструктура
    /// подтверждает системе уход в сон.
    func start(onWillSleep: @escaping @Sendable () async -> Void,
               onDidWake: @escaping @Sendable () -> Void) async
    func stop() async
}

/// Сведения о пути для инфо-строки «Сеть» в поповере.
struct NetworkPathInfo: Hashable, Sendable {
    let isSatisfied: Bool
    let interfaceDescription: String
    let gateway: String?

    init(isSatisfied: Bool, interfaceDescription: String, gateway: String? = nil) {
        self.isSatisfied = isSatisfied
        self.interfaceDescription = interfaceDescription
        self.gateway = gateway
    }
}

enum RuleGroupGatewayError: Error, Hashable {
    case helperUnavailable(String)
    case cliFailed(String)
    case unparsableModel(String)
    /// Little Snitch запрещает доступ своему CLI (собственный тумблер LS,
    /// отдельный от одобрения helper). Проверено на целевой машине:
    /// `Error: command line tool is not authorized to make changes.`
    case cliNotAuthorized
    /// Helper не принял failsafe-конфиг (не расшифровал или не сохранил).
    case failsafeRejected(String)

    var message: String {
        switch self {
        case .helperUnavailable(let text): "helper недоступен: \(text)"
        case .cliFailed(let text): "littlesnitch вернул ошибку: \(text)"
        case .unparsableModel(let text): "не удалось разобрать модель LS: \(text)"
        case .cliNotAuthorized:
            "Little Snitch не разрешает доступ своему CLI — включи его в Little Snitch → Настройки → Безопасность"
        case .failsafeRejected(let text): "helper не принял failsafe-конфиг: \(text)"
        }
    }

    /// Признак того, что виноват не helper, а запрет со стороны Little Snitch:
    /// UI обязан показывать разные подсказки, иначе пользователь ищет проблему
    /// не там.
    var isLittleSnitchAuthorization: Bool { self == .cliNotAuthorized }

    /// Распознаёт запрет LS по тексту вывода CLI.
    static func fromCLI(_ text: String) -> RuleGroupGatewayError {
        text.lowercased().contains("not authorized")
            ? .cliNotAuthorized
            : .cliFailed(text)
    }
}

protocol RuleGroupGateway: Sendable {
    func helperVersion() async throws -> String
    func listRuleGroups() async throws -> [RuleGroup]
    func setRuleGroup(_ name: String, enabled: Bool) async throws
}

/// Синхронизация failsafe-конфига helper (D5): dead-man's switch и закрытие
/// на загрузке ОС живут в helper и узнают о режиме только этой операцией.
/// Отдельный порт, а не расширение `RuleGroupGateway`: реактивным use cases
/// failsafe не нужен.
protocol FailsafeSyncing: Sendable {
    func syncFailsafe(_ config: FailsafeConfig) async throws
}

protocol WifiPowerGateway: Sendable {
    /// Эскалация ФТ-9: root не требуется.
    func turnWifiOff() async throws
}

/// Уведомление пользователю (ФТ-5) с категорией для отключаемых тумблеров.
struct AppNotification: Hashable, Sendable {
    enum Category: Hashable, Sendable {
        case transition
        case error
    }

    let category: Category
    let title: String
    let body: String
}

protocol NotificationPresenting: Sendable {
    func present(_ notification: AppNotification) async
}

protocol JournalStore: Sendable {
    func append(_ event: JournalEvent) async
    func recent(limit: Int) async -> [JournalEvent]
    func clear() async
}

protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

protocol Clock: Sendable {
    func now() async -> Instant
    func sleep(seconds: Double) async
}
