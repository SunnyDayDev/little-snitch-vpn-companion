/// Reconcile (§5 SPEC.md): фактическое состояние групп LS приводится к
/// целевому для текущего состояния. Никакой истории — всегда сверка с фактом.
struct ApplyPolicy: Sendable {
    enum Outcome: Hashable, Sendable {
        /// Изменений не потребовалось либо они применены.
        case applied(operations: [RuleGroupOperation], missingGroups: [String])
        /// Состояние не определяет целевой набор (Offline/Paused).
        case skippedNoTarget
        /// `observeOnly`: группы намеренно не тронуты.
        case skippedObserveOnly(operations: [RuleGroupOperation])
        /// Helper или CLI не сработали — состояние детектора не меняется.
        case failed(RuleGroupGatewayError)
    }

    let gateway: any RuleGroupGateway
    let journal: any JournalStore
    let clock: any Clock

    func run(state: EgressState, settings: AppSettings) async -> Outcome {
        guard LeakPolicy.targetEnabledGroups(for: state,
                                             mapping: settings.mapping) != nil else {
            return .skippedNoTarget
        }

        let actual: [RuleGroup]
        do {
            actual = try await gateway.listRuleGroups()
        } catch {
            return await fail(error, state: state)
        }

        guard let plan = LeakPolicy.plan(for: state,
                                         mapping: settings.mapping,
                                         actual: actual) else {
            return .skippedNoTarget
        }

        for name in plan.missingGroups {
            await journalError("группа «\(name)» не найдена в Little Snitch")
        }

        guard !settings.observeOnly else {
            if !plan.isEmpty {
                await journalAction("режим наблюдения: группы не тронуты (\(describe(plan.operations)))")
            }
            return .skippedObserveOnly(operations: plan.operations)
        }

        for operation in plan.operations {
            do {
                try await gateway.setRuleGroup(operation.name, enabled: operation.enable)
                await journalAction("группа «\(operation.name)» \(operation.enable ? "включена" : "выключена")")
            } catch {
                return await fail(error, state: state)
            }
        }

        return .applied(operations: plan.operations, missingGroups: plan.missingGroups)
    }

    private func fail(_ error: any Error, state: EgressState) async -> Outcome {
        let gatewayError = error as? RuleGroupGatewayError
            ?? .helperUnavailable(String(describing: error))
        await journalError(gatewayError.message)
        return .failed(gatewayError)
    }

    private func describe(_ operations: [RuleGroupOperation]) -> String {
        operations
            .map { "\($0.name) → \($0.enable ? "вкл" : "выкл")" }
            .joined(separator: ", ")
    }

    private func journalAction(_ text: String) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          kind: .action(text)))
    }

    private func journalError(_ text: String) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          kind: .error(text)))
    }
}
