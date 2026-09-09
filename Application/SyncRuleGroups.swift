/// Получение актуального списка rule groups из Little Snitch (ФТ-3) —
/// для вкладки «Группы» и для reconcile.
///
/// Одноимённые группы (локальная и подписка с одним именем) схлопываются
/// здесь, а не в helper: при включении по имени различить их нельзя, а
/// предупредить пользователя может только журнал приложения.
struct SyncRuleGroups: Sendable {
    enum Outcome: Hashable, Sendable {
        case synced([RuleGroup], helperVersion: String?)
        case failed(RuleGroupGatewayError)
    }

    let gateway: any RuleGroupGateway
    let journal: any JournalStore
    let clock: any Clock

    func run() async -> Outcome {
        do {
            let version = try? await gateway.helperVersion()
            let listed = try await gateway.listRuleGroups()
            let (groups, duplicates) = Self.dedupe(listed)
            for name in duplicates {
                await journal.append(JournalEvent(
                    time: await clock.now(),
                    trigger: .user,
                    kind: .warning("одноимённые группы в Little Snitch: «\(name)» — "
                        + "включаются по имени, различить их нельзя")))
            }
            await journal.append(JournalEvent(
                time: await clock.now(),
                trigger: .user,
                kind: .fact("список групп из LS: \(groups.count) шт. "
                    + "(\(groups.map(\.name).prefix(5).joined(separator: ", ")))")))
            return .synced(groups, helperVersion: version)
        } catch {
            let gatewayError = error as? RuleGroupGatewayError
                ?? .helperUnavailable(String(describing: error))
            await journal.append(JournalEvent(time: await clock.now(),
                                              trigger: .user,
                                              kind: .error(gatewayError.message)))
            return .failed(gatewayError)
        }
    }

    /// Оставляет первую запись на каждое имя (helper отдаёт список в
    /// детерминированном порядке) и возвращает имена, встретившиеся повторно.
    static func dedupe(_ groups: [RuleGroup]) -> (unique: [RuleGroup], duplicates: [String]) {
        var seen: Set<String> = []
        var unique: [RuleGroup] = []
        var duplicates: [String] = []
        for group in groups {
            if seen.insert(group.name).inserted {
                unique.append(group)
            } else if !duplicates.contains(group.name) {
                duplicates.append(group.name)
            }
        }
        return (unique, duplicates)
    }
}
