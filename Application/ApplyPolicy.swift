/// Reconcile (§5 SPEC.md): фактическое состояние групп LS приводится к
/// цели, которую арбитраж свёл из желаний всех включённых детекторов.
/// Никакой истории — всегда сверка с фактом.
struct ApplyPolicy: Sendable {
    enum Outcome: Hashable, Sendable {
        /// Изменений не потребовалось либо они применены.
        case applied(operations: [RuleGroupOperation], missingGroups: [String])
        /// Ни у одной группы нет определённого целевого состояния (только
        /// реактивные детекторы в Offline/Checking/Paused или детекторов нет).
        case skippedNoTarget
        /// `observeOnly`: группы намеренно не тронуты.
        case skippedObserveOnly(operations: [RuleGroupOperation])
        /// Helper или CLI не сработали — состояние детекторов не меняется.
        case failed(RuleGroupGatewayError)
    }

    let gateway: any RuleGroupGateway
    let journal: any JournalStore
    let clock: any Clock

    /// Привести группы к решению арбитража. Группы без определённого
    /// целевого состояния в решение не входят и не трогаются — так же, как
    /// группы вне маппингов всех детекторов.
    func run(decision: GroupArbiter.Decision, settings: AppSettings) async -> Outcome {
        guard !decision.managed.isEmpty else { return .skippedNoTarget }

        let actual: [RuleGroup]
        do {
            actual = try await gateway.listRuleGroups()
        } catch {
            return await fail(error)
        }

        let plan = LeakPolicy.plan(actual: actual, target: decision.enable,
                                   managed: decision.managed)

        for name in plan.missingGroups {
            await journalError("группа «\(name)» не найдена в Little Snitch",
                               detector: Self.names(settings.owners(of: name)))
        }

        guard !settings.observeOnly else {
            if !plan.isEmpty {
                // ФТ-10: обкатка строгого режима должна быть видна в журнале —
                // иначе непонятно, когда бы он реально закрыл трафик.
                let closing = Set(plan.operations.filter(\.enable).map(\.name))
                let strictClosers = settings.strictDetectors
                    .filter { !closing.isDisjoint(with: $0.groups) }
                await journalAction(strictClosers.isEmpty
                    ? "режим наблюдения: группы не тронуты (\(describe(plan.operations)))"
                    : "строгий режим: закрыл бы группы — наблюдение, не тронуты (\(describe(plan.operations)))",
                    detector: Self.names(strictClosers))
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

    /// Быстрое безусловное закрытие на завершении приложения и засыпании:
    /// без листинга — включение идемпотентно, а бюджет времени мал (холодный
    /// вызов helper стоит до 6 с, и листинг+включение в бюджет не влезали).
    /// Ошибка одной группы не прерывает остальные: закрыть максимум возможного.
    func forceEnable(groups: [String], settings: AppSettings) async -> Outcome {
        guard !settings.observeOnly else {
            // ФТ-10: обкатка строгого режима видна в журнале и на быстром
            // пути — иначе закрытия на завершении и на засыпании были бы
            // невидимы и режим наблюдения врал бы о своей бездеятельности.
            let operations = groups.map { RuleGroupOperation(name: $0, enable: true) }
            if !operations.isEmpty {
                await journalAction("строгий режим: закрыл бы группы — наблюдение, не тронуты (\(describe(operations)))",
                                    detector: Self.names(settings.strictDetectors))
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

    /// Поле «детектор» записи: одно имя или перечисление, если событие
    /// касается нескольких детекторов сразу.
    private static func names(_ detectors: [DetectorConfig]) -> String? {
        detectors.isEmpty ? nil : detectors.map(\.name).joined(separator: ", ")
    }

    private func journalAction(_ text: String, detector: String? = nil) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          detector: detector,
                                          kind: .action(text)))
    }

    private func journalError(_ text: String, detector: String? = nil) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          detector: detector,
                                          kind: .error(text)))
    }
}
