import Testing

@Suite("LeakPolicy и reconcile")
struct LeakPolicyTests {
    private let mapping = RuleGroupMapping(leakGroups: ["VPN down"])

    @Test("Целевой набор групп по состояниям")
    func targetsPerState() {
        #expect(LeakPolicy.targetEnabledGroups(for: .leak, mapping: mapping) == ["VPN down"])
        #expect(LeakPolicy.targetEnabledGroups(for: .protected, mapping: mapping) == [])
        #expect(LeakPolicy.targetEnabledGroups(for: .offline, mapping: mapping) == nil)
        #expect(LeakPolicy.targetEnabledGroups(for: .paused, mapping: mapping) == nil)
    }

    @Test("Leak включает выключенную группу")
    func leakEnablesGroup() throws {
        let plan = try #require(LeakPolicy.plan(
            for: .leak, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: false)]))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: true)])
        #expect(plan.missingGroups.isEmpty)
    }

    @Test("Protected выключает включённую группу")
    func protectedDisablesGroup() throws {
        let plan = try #require(LeakPolicy.plan(
            for: .protected, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: true)]))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: false)])
    }

    @Test("Reconcile идемпотентен: состояние уже целевое → операций нет")
    func idempotentWhenAlreadyCorrect() throws {
        let leakPlan = try #require(LeakPolicy.plan(
            for: .leak, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: true)]))
        #expect(leakPlan.isEmpty)

        let protectedPlan = try #require(LeakPolicy.plan(
            for: .protected, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: false)]))
        #expect(protectedPlan.isEmpty)
    }

    @Test("Offline, Checking и Paused не дают плана вовсе")
    func noPlanForOfflineAndPaused() {
        let actual = [RuleGroup(name: "VPN down", enabled: true)]
        #expect(LeakPolicy.plan(for: .offline, mapping: mapping, actual: actual) == nil)
        #expect(LeakPolicy.plan(for: .checking, mapping: mapping, actual: actual) == nil)
        #expect(LeakPolicy.plan(for: .paused, mapping: mapping, actual: actual) == nil)
    }

    // MARK: - Строгий режим

    @Test("Строгий режим: открыто только при Protected")
    func strictTargetsPerState() {
        #expect(LeakPolicy.targetEnabledGroups(for: .protected, mode: .strict,
                                               mapping: mapping) == [])
        for state in [EgressState.leak, .offline, .checking, .paused] {
            #expect(LeakPolicy.targetEnabledGroups(for: state, mode: .strict,
                                                   mapping: mapping) == ["VPN down"])
        }
    }

    @Test("Строгий режим: Offline включает выключенную группу")
    func strictOfflineCloses() throws {
        let plan = try #require(LeakPolicy.plan(
            for: .offline, mode: .strict, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: false)]))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: true)])
    }

    @Test("Строгий режим: Protected выключает, закрытое состояние идемпотентно")
    func strictProtectedOpens() throws {
        let open = try #require(LeakPolicy.plan(
            for: .protected, mode: .strict, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: true)]))
        #expect(open.operations == [RuleGroupOperation(name: "VPN down", enable: false)])

        let closed = try #require(LeakPolicy.plan(
            for: .checking, mode: .strict, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: true)]))
        #expect(closed.isEmpty)
    }

    @Test("Чужие группы не трогаются никогда")
    func leavesUnmanagedGroupsAlone() throws {
        let actual = [
            RuleGroup(name: "VPN down", enabled: false),
            RuleGroup(name: "Пользовательская группа", enabled: true),
            RuleGroup(name: "Блок рекламы", enabled: false),
        ]
        let plan = try #require(LeakPolicy.plan(for: .leak, mapping: mapping, actual: actual))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: true)])
    }

    @Test("Несуществующее имя группы попадает в missingGroups")
    func reportsMissingGroups() throws {
        let mapping = RuleGroupMapping(leakGroups: ["VPN down", "Опечатка"])
        let plan = try #require(LeakPolicy.plan(
            for: .leak, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: false)]))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: true)])
        #expect(plan.missingGroups == ["Опечатка"])
    }

    @Test("Reconcile на старте чинит рассинхрон, оставшийся с прошлого раза")
    func fixesDriftOnStart() throws {
        // Приложение стартует в Protected, а группа осталась включённой
        let plan = try #require(LeakPolicy.plan(
            for: .protected, mapping: mapping,
            actual: [RuleGroup(name: "VPN down", enabled: true)]))
        #expect(plan.operations == [RuleGroupOperation(name: "VPN down", enable: false)])
    }

    @Test("Несколько групп обрабатываются в стабильном порядке")
    func stableOrder() throws {
        let mapping = RuleGroupMapping(leakGroups: ["Б", "А", "В"])
        let plan = try #require(LeakPolicy.plan(
            for: .leak, mapping: mapping,
            actual: [
                RuleGroup(name: "А", enabled: false),
                RuleGroup(name: "Б", enabled: false),
                RuleGroup(name: "В", enabled: false),
            ]))
        #expect(plan.operations.map(\.name) == ["А", "Б", "В"])
    }

    @Test("Пустой маппинг ничего не делает")
    func emptyMappingIsNoop() throws {
        let plan = try #require(LeakPolicy.plan(
            for: .leak, mapping: RuleGroupMapping(),
            actual: [RuleGroup(name: "VPN down", enabled: false)]))
        #expect(plan.isEmpty)
        #expect(plan.missingGroups.isEmpty)
    }
}
