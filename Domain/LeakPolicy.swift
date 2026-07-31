/// Политика «состояние → целевой набор включённых групп» и вычисление плана
/// reconcile. Никакой истории: план всегда считается от фактического состояния.
enum LeakPolicy {
    /// `nil` означает «состояние не определяет целевой набор». В реактивном
    /// режиме так ведут себя Offline, Checking и Paused; в строгом целевой
    /// набор определён всегда: открыто — только доказанный Protected.
    static func targetEnabledGroups(for state: EgressState,
                                    mode: ProtectionMode = .reactive,
                                    mapping: RuleGroupMapping) -> Set<String>? {
        switch mode {
        case .reactive:
            switch state {
            case .leak: mapping.managedGroups
            case .protected: []
            case .offline, .checking, .paused: nil
            }
        case .strict:
            state == .protected ? [] : mapping.managedGroups
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
                     mode: ProtectionMode = .reactive,
                     mapping: RuleGroupMapping,
                     actual: [RuleGroup]) -> ReconcilePlan? {
        guard let target = targetEnabledGroups(for: state, mode: mode,
                                               mapping: mapping) else {
            return nil
        }
        return plan(actual: actual, target: target, managed: mapping.managedGroups)
    }
}
