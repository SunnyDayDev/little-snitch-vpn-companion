/// Rule group Little Snitch: имя и фактическое состояние. Приложение никогда
/// не меняет правила внутри группы — только включает и выключает группу.
struct RuleGroup: Hashable, Codable {
    let name: String
    let enabled: Bool

    init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
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
