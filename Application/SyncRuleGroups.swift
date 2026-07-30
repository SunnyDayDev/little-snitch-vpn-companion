/// Получение актуального списка rule groups из Little Snitch (ФТ-3) —
/// для вкладки «Группы» и для reconcile.
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
            let groups = try await gateway.listRuleGroups()
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
}
