/// Политика «состояние → целевой набор включённых групп» и вычисление плана
/// reconcile. Никакой истории: план всегда считается от фактического состояния.
enum LeakPolicy {
    /// `nil` означает «состояние не определяет целевой набор» — при Offline
    /// и Paused группы не трогаются вовсе.
    static func targetEnabledGroups(for state: EgressState,
                                    mapping: RuleGroupMapping) -> Set<String>? {
        switch state {
        case .leak: mapping.managedGroups
        case .protected: []
        case .offline, .paused: nil
        }
    }

    /// Диф фактического состояния и целевого. Затрагиваются только группы из
    /// маппинга: остальные могли быть включены пользователем вручную.
    static func plan(actual: [RuleGroup],
                     target: Set<String>,
                     managed: Set<String>) -> ReconcilePlan {
        var actualByName: [String: Bool] = [:]
        for group in actual { actualByName[group.name] = group.enabled }

        var operations: [RuleGroupOperation] = []
        var missing: [String] = []

        for name in managed.sorted() {
            guard let isEnabled = actualByName[name] else {
                missing.append(name)
                continue
            }
            let shouldBeEnabled = target.contains(name)
            if isEnabled != shouldBeEnabled {
                operations.append(RuleGroupOperation(name: name, enable: shouldBeEnabled))
            }
        }

        return ReconcilePlan(operations: operations, missingGroups: missing)
    }

    /// План для состояния целиком. `nil` — состояние не требует вмешательства.
    static func plan(for state: EgressState,
                     mapping: RuleGroupMapping,
                     actual: [RuleGroup]) -> ReconcilePlan? {
        guard let target = targetEnabledGroups(for: state, mapping: mapping) else {
            return nil
        }
        return plan(actual: actual, target: target, managed: mapping.managedGroups)
    }
}
