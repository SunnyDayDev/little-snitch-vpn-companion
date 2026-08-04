/// Reconcile (§5 SPEC.md): фактическое состояние групп LS приводится к
/// целевому для текущего состояния и режима защиты. Никакой истории — всегда
/// сверка с фактом.
struct ApplyPolicy: Sendable {
    enum Outcome: Hashable, Sendable {
        /// Изменений не потребовалось либо они применены.
        case applied(operations: [RuleGroupOperation], missingGroups: [String])
        /// Состояние не определяет целевой набор (реактивный Offline/Checking/Paused).
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
        guard let target = LeakPolicy.targetEnabledGroups(
            for: state, mode: settings.protectionMode,
            mapping: settings.mapping) else {
            return .skippedNoTarget
        }
        return await run(target: target, settings: settings)
    }

    /// Привести группы к явной цели, минуя политику состояния: переключение
    /// режима на лету и закрытие перед завершением приложения не выражаются
    /// парой «состояние + режим».
    func run(target: Set<String>, settings: AppSettings) async -> Outcome {
        let actual: [RuleGroup]
        do {
            actual = try await gateway.listRuleGroups()
        } catch {
            return await fail(error)
        }

        let plan = LeakPolicy.plan(actual: actual, target: target,
                                   managed: settings.mapping.managedGroups)

        for name in plan.missingGroups {
            await journalError("группа «\(name)» не найдена в Little Snitch")
        }

        guard !settings.observeOnly else {
            if !plan.isEmpty {
                // ФТ-10: обкатка строгого режима должна быть видна в журнале —
                // иначе непонятно, когда бы он реально закрыл трафик.
                let wouldClose = settings.protectionMode == .strict
                    && plan.operations.contains { $0.enable }
                await journalAction(wouldClose
                    ? "строгий режим: закрыл бы группы — наблюдение, не тронуты (\(describe(plan.operations)))"
                    : "режим наблюдения: группы не тронуты (\(describe(plan.operations)))")
            }
            return .skippedObserveOnly(operations: plan.operations)
        }

        for operation in plan.operations {
            do {
                try await gateway.setRuleGroup(operation.name, enabled: operation.enable)
                await journalAction("группа «\(operation.name)» \(operation.enable ? "включена" : "выключена")")
            } catch {
                return await fail(error)
            }
        }

        return .applied(operations: plan.operations, missingGroups: plan.missingGroups)
    }

    /// Быстрое безусловное закрытие на завершении приложения: без листинга —
    /// включение идемпотентно, а бюджет времени на выходе мал (холодный вызов
    /// helper стоит до 6 с, и листинг+включение в бюджет не влезали). Ошибка
    /// одной группы не прерывает остальные: закрыть максимум возможного.
    func forceEnable(groups: [String], settings: AppSettings) async -> Outcome {
        guard !settings.observeOnly else {
            // ФТ-10: обкатка строгого режима видна в журнале и на быстром
            // пути — иначе закрытия на завершении и на засыпании были бы
            // невидимы и режим наблюдения врал бы о своей бездеятельности.
            let operations = groups.map { RuleGroupOperation(name: $0, enable: true) }
            if !operations.isEmpty {
                await journalAction("строгий режим: закрыл бы группы — наблюдение, не тронуты (\(describe(operations)))")
            }
            return .skippedObserveOnly(operations: operations)
        }
        var operations: [RuleGroupOperation] = []
        var lastError: RuleGroupGatewayError?
        for name in groups {
            do {
                try await gateway.setRuleGroup(name, enabled: true)
                operations.append(RuleGroupOperation(name: name, enable: true))
                await journalAction("группа «\(name)» включена")
            } catch {
                let gatewayError = error as? RuleGroupGatewayError
                    ?? .helperUnavailable(String(describing: error))
                await journalError(gatewayError.message)
                lastError = gatewayError
            }
        }
        if let lastError { return .failed(lastError) }
        return .applied(operations: operations, missingGroups: [])
    }

    private func fail(_ error: any Error) async -> Outcome {
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
