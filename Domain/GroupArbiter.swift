/// Арбитраж групп между детекторами (D2 design.md). Каждый детектор отвечает
/// за свои группы через `LeakPolicy.targetEnabledGroups`, арбитр сводит
/// ответы в одну цель:
///
/// | Желания детекторов, содержащих группу                  | Итог          |
/// | ------------------------------------------------------ | ------------- |
/// | хотя бы один требует включить                          | включить      |
/// | никто не требует включить, хотя бы один — выключить    | выключить     |
/// | ни один не определяет                                  | не трогать    |
///
/// Включение побеждает: спокойный детектор не открывает группу, по которой
/// другой подтвердил утечку, — иначе ломался бы инвариант строгого режима.
enum GroupArbiter {
    /// Желание одного детектора: его группы и целевой набор включённых из них.
    struct Participant: Hashable {
        let groups: Set<String>
        /// `nil` — детектор не определяет состояние своих групп (реактивный
        /// Offline/Checking/Paused).
        let target: Set<String>?

        init(groups: Set<String>, target: Set<String>?) {
            self.groups = groups
            self.target = target
        }

        /// Желание по паре «состояние + режим» — обычный reconcile.
        init(state: EgressState, mode: ProtectionMode, mapping: RuleGroupMapping) {
            groups = mapping.managedGroups
            target = LeakPolicy.targetEnabledGroups(for: state, mode: mode, mapping: mapping)
        }
    }

    /// Итог арбитража. Группы вне обоих множеств не трогаются.
    struct Decision: Hashable {
        let enable: Set<String>
        let disable: Set<String>

        /// Группы, которыми управляет этот reconcile, — `managed` для
        /// `LeakPolicy.plan`.
        var managed: Set<String> { enable.union(disable) }

        static let empty = Decision(enable: [], disable: [])
    }

    static func decide(_ participants: [Participant]) -> Decision {
        var enable: Set<String> = []
        var disable: Set<String> = []
        for participant in participants {
            guard let target = participant.target else { continue }
            for group in participant.groups {
                if target.contains(group) {
                    enable.insert(group)
                } else {
                    disable.insert(group)
                }
            }
        }
        return Decision(enable: enable, disable: disable.subtracting(enable))
    }

    /// Обычный reconcile по детекторам: выключенные не участвуют — их
    /// последний вердикт больше никого не держит. Детектор без известного
    /// состояния — Offline, как машина до первого события.
    static func decide(detectors: [DetectorConfig],
                       states: [DetectorID: EgressState]) -> Decision {
        decide(detectors.filter(\.isEnabled).map { detector in
            Participant(state: states[detector.id] ?? .offline,
                        mode: detector.protectionMode,
                        mapping: detector.mapping)
        })
    }
}
