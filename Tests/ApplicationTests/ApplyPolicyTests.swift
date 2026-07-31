import Testing

@Suite("ApplyPolicy — reconcile")
struct ApplyPolicyTests {
    private func makePolicy(_ gateway: FakeRuleGroupGateway,
                            journal: FakeJournal = FakeJournal()) -> ApplyPolicy {
        ApplyPolicy(gateway: gateway, journal: journal, clock: ImmediateClock())
    }

    @Test("Leak включает выключенную группу")
    func enablesGroupOnLeak() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        let outcome = await makePolicy(gateway).run(state: .leak,
                                                    settings: TestData.settings())
        #expect(outcome == .applied(operations: [RuleGroupOperation(name: "VPN down", enable: true)],
                                    missingGroups: []))
        #expect(await gateway.groups["VPN down"] == true)
    }

    @Test("Protected выключает включённую группу")
    func disablesGroupOnProtected() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": true])
        _ = await makePolicy(gateway).run(state: .protected, settings: TestData.settings())
        #expect(await gateway.groups["VPN down"] == false)
    }

    @Test("Повторный reconcile идемпотентен — лишних вызовов CLI нет")
    func idempotent() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": true])
        let policy = makePolicy(gateway)
        let outcome = await policy.run(state: .leak, settings: TestData.settings())
        #expect(outcome == .applied(operations: [], missingGroups: []))
        #expect(await gateway.operations.isEmpty)
    }

    @Test("Offline и Paused не трогают группы вовсе")
    func offlineAndPausedSkip() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": true])
        let policy = makePolicy(gateway)
        #expect(await policy.run(state: .offline, settings: TestData.settings()) == .skippedNoTarget)
        #expect(await policy.run(state: .paused, settings: TestData.settings()) == .skippedNoTarget)
        #expect(await gateway.listCallCount == 0)
        #expect(await gateway.groups["VPN down"] == true)
    }

    @Test("Режим наблюдения: план посчитан, но группы не тронуты")
    func observeOnlySkipsOperations() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        var settings = TestData.settings()
        settings.observeOnly = true
        let outcome = await makePolicy(gateway).run(state: .leak, settings: settings)
        #expect(outcome == .skippedObserveOnly(operations: [RuleGroupOperation(name: "VPN down", enable: true)]))
        #expect(await gateway.groups["VPN down"] == false)
    }

    @Test("Ошибка списка групп → failed, группы не тронуты")
    func listFailure() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        await gateway.failList(with: .helperUnavailable("нет соединения"))
        let outcome = await makePolicy(gateway).run(state: .leak, settings: TestData.settings())
        #expect(outcome == .failed(.helperUnavailable("нет соединения")))
        #expect(await gateway.operations.isEmpty)
    }

    @Test("Ошибка переключения группы → failed и запись в журнал")
    func setFailure() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        await gateway.failSet(with: .cliFailed("exit 1"))
        let journal = FakeJournal()
        let outcome = await makePolicy(gateway, journal: journal)
            .run(state: .leak, settings: TestData.settings())
        #expect(outcome == .failed(.cliFailed("exit 1")))
        let errors = await journal.events.filter { $0.kind.category == .error }
        #expect(errors.count == 1)
    }

    @Test("Несуществующее имя группы: внятная ошибка в журнале, без падения")
    func missingGroupIsReported() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        let journal = FakeJournal()
        let settings = TestData.settings(leakGroups: ["VPN down", "Опечатка"])
        let outcome = await makePolicy(gateway, journal: journal)
            .run(state: .leak, settings: settings)

        #expect(outcome == .applied(operations: [RuleGroupOperation(name: "VPN down", enable: true)],
                                    missingGroups: ["Опечатка"]))
        let errors = await journal.events.compactMap { event -> String? in
            if case .error(let text) = event.kind { return text } else { return nil }
        }
        #expect(errors.contains { $0.contains("Опечатка") })
    }

    @Test("Группы вне маппинга не трогаются")
    func leavesForeignGroupsAlone() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false, "Моя группа": true])
        _ = await makePolicy(gateway).run(state: .leak, settings: TestData.settings())
        #expect(await gateway.groups["Моя группа"] == true)
        #expect(await gateway.operations.map(\.name) == ["VPN down"])
    }

    // MARK: - Строгий режим

    @Test("Строгий режим: Offline и Checking включают группы")
    func strictClosesOnUncertainty() async {
        for state in [EgressState.offline, .checking, .paused] {
            let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
            let outcome = await makePolicy(gateway)
                .run(state: state, settings: TestData.settings(mode: .strict))
            #expect(outcome == .applied(
                operations: [RuleGroupOperation(name: "VPN down", enable: true)],
                missingGroups: []))
            #expect(await gateway.groups["VPN down"] == true)
        }
    }

    @Test("Строгий режим: Protected открывает")
    func strictProtectedOpens() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": true])
        _ = await makePolicy(gateway)
            .run(state: .protected, settings: TestData.settings(mode: .strict))
        #expect(await gateway.groups["VPN down"] == false)
    }

    @Test("Явная цель: переходный reconcile при смене режима")
    func explicitTargetRun() async {
        // strict → reactive из Offline: цель пустая — открыть
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": true])
        let outcome = await makePolicy(gateway)
            .run(target: [], settings: TestData.settings())
        #expect(outcome == .applied(
            operations: [RuleGroupOperation(name: "VPN down", enable: false)],
            missingGroups: []))
        #expect(await gateway.groups["VPN down"] == false)
    }

    @Test("Явная цель уважает observeOnly")
    func explicitTargetRespectsObserveOnly() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        var settings = TestData.settings(mode: .strict)
        settings.observeOnly = true
        let outcome = await makePolicy(gateway)
            .run(target: ["VPN down"], settings: settings)
        #expect(outcome == .skippedObserveOnly(
            operations: [RuleGroupOperation(name: "VPN down", enable: true)]))
        #expect(await gateway.groups["VPN down"] == false)
    }
}
