/// Вид rule group Little Snitch. Влияет только на подпись во вкладке
/// «Группы»: включается и выключается любая группа одинаково — по имени.
enum RuleGroupKind: String, Hashable, Codable {
    /// Встроенная группа Little Snitch («macOS Services», «iCloud Services»).
    case builtin
    /// Локальная группа, созданная пользователем.
    case local
    /// Подписка по URL: правила приходят из `.lsrules` на сервере.
    case remote
}

/// Rule group Little Snitch: имя, фактическое состояние и вид. Приложение
/// никогда не меняет правила внутри группы — только включает и выключает группу.
struct RuleGroup: Hashable, Codable {
    let name: String
    let enabled: Bool
    /// `nil` — helper вид не сообщил: старая версия демона или запасной разбор
    /// модели, который о видах не знает.
    let kind: RuleGroupKind?

    init(name: String, enabled: Bool, kind: RuleGroupKind? = nil) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
    }
}

/// Маппинг «состояние → какие группы включены» (ФТ-2). В v1 настраивается
/// только набор групп для Leak; Protected — их зеркальное выключение.
struct RuleGroupMapping: Hashable, Codable {
    var leakGroups: [String]

    init(leakGroups: [String] = []) {
        self.leakGroups = leakGroups
    }

    /// Группы, которыми управляет приложение. Всё, что вне этого набора,
    /// не трогается никогда — пользователь мог включить их сам.
    var managedGroups: Set<String> { Set(leakGroups) }
}

struct RuleGroupOperation: Hashable, Codable {
    let name: String
    let enable: Bool
}

/// Что нужно сделать, чтобы фактическое состояние групп совпало с целевым.
struct ReconcilePlan: Hashable {
    let operations: [RuleGroupOperation]
    /// Имена из маппинга, которых нет в Little Snitch, — повод для внятной
    /// ошибки в журнале и уведомления (сценарий 12 §14 SPEC.md).
    let missingGroups: [String]

    var isEmpty: Bool { operations.isEmpty }
}
