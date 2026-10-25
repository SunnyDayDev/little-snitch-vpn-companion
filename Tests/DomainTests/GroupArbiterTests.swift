import Testing

/// Таблица арбитража дельты rule-group-control — каждая строка и каждый
/// сценарий покрыты тестом.
@Suite("GroupArbiter")
struct GroupArbiterTests {
    private func detector(_ name: String,
                          mode: ProtectionMode = .reactive,
                          enabled: Bool = true,
                          groups: [String]) -> DetectorConfig {
        DetectorConfig(id: DetectorID(name), name: name, isEnabled: enabled,
                       protectionMode: mode, groups: groups)
    }

    private func decide(_ entries: [(DetectorConfig, EgressState)]) -> GroupArbiter.Decision {
        GroupArbiter.decide(
            detectors: entries.map(\.0),
            states: Dictionary(uniqueKeysWithValues: entries.map { ($0.0.id, $0.1) }))
    }

    // MARK: - Строки таблицы

    @Test("Хотя бы один требует включить → включена")
    func anyEnableWins() {
        let decision = GroupArbiter.decide([
            .init(groups: ["G"], target: ["G"]),
            .init(groups: ["G"], target: []),
        ])
        #expect(decision == .init(enable: ["G"], disable: []))
    }

    @Test("Никто не требует включить, хотя бы один — выключить → выключена")
    func disableWithoutEnable() {
        let decision = GroupArbiter.decide([
            .init(groups: ["G"], target: []),
            .init(groups: ["G"], target: nil),
        ])
        #expect(decision == .init(enable: [], disable: ["G"]))
    }

    @Test("Ни один не определяет → не трогать")
    func nobodyDecides() {
        let decision = GroupArbiter.decide([
            .init(groups: ["G"], target: nil),
            .init(groups: ["G"], target: nil),
        ])
        #expect(decision == .empty)
        #expect(decision.managed.isEmpty)
    }

    // MARK: - Сценарии

    @Test("Один закрывает — закрыто: A Leak реактивный, B Protected реактивный")
    func leakBeatsProtected() {
        let decision = decide([
            (detector("A", groups: ["G"]), .leak),
            (detector("B", groups: ["G"]), .protected),
        ])
        #expect(decision.enable == ["G"])
        #expect(decision.disable.isEmpty)
    }

    @Test("Строгий офлайн держит общую группу: A Offline строгий, B Protected строгий")
    func strictOfflineHoldsSharedGroup() {
        let decision = decide([
            (detector("A", mode: .strict, groups: ["G"]), .offline),
            (detector("B", mode: .strict, groups: ["G"]), .protected),
        ])
        #expect(decision.enable == ["G"])
    }

    @Test("Все согласны открыть: A и B в Protected")
    func allProtectedOpen() {
        let decision = decide([
            (detector("A", groups: ["G"]), .protected),
            (detector("B", mode: .strict, groups: ["G"]), .protected),
        ])
        #expect(decision == .init(enable: [], disable: ["G"]))
    }

    @Test("Один открывает, другой не определяет: A Protected, B Offline (оба реактивные)")
    func protectedOpensWhenOtherUndecided() {
        let decision = decide([
            (detector("A", groups: ["G"]), .protected),
            (detector("B", groups: ["G"]), .offline),
        ])
        #expect(decision == .init(enable: [], disable: ["G"]))
    }

    @Test("Никто не определяет: только реактивные, все в Offline")
    func reactiveOfflineLeavesGroupAlone() {
        let decision = decide([
            (detector("A", groups: ["G"]), .offline),
            (detector("B", groups: ["G"]), .checking),
            (detector("C", groups: ["G"]), .paused),
        ])
        #expect(decision == .empty)
    }

    @Test("Выключенный детектор не участвует: A выключен в Leak, B Protected")
    func disabledDetectorIsIgnored() {
        let decision = decide([
            (detector("A", enabled: false, groups: ["G"]), .leak),
            (detector("B", groups: ["G"]), .protected),
        ])
        #expect(decision == .init(enable: [], disable: ["G"]))
    }

    // MARK: - Границы

    @Test("Группа в трёх детекторах: один Leak перевешивает два Protected")
    func groupInThreeDetectors() {
        let decision = decide([
            (detector("A", groups: ["G", "A-only"]), .protected),
            (detector("B", mode: .strict, groups: ["G"]), .protected),
            (detector("C", groups: ["G", "C-only"]), .leak),
        ])
        #expect(decision.enable == ["G", "C-only"])
        #expect(decision.disable == ["A-only"])
    }

    @Test("Группа в трёх детекторах: все Protected — открыто")
    func groupInThreeDetectorsAllProtected() {
        let decision = decide([
            (detector("A", groups: ["G"]), .protected),
            (detector("B", mode: .strict, groups: ["G"]), .protected),
            (detector("C", groups: ["G"]), .protected),
        ])
        #expect(decision == .init(enable: [], disable: ["G"]))
    }

    @Test("Пустой набор детекторов: решать нечего")
    func emptyDetectorSet() {
        #expect(GroupArbiter.decide([]) == .empty)
        #expect(decide([]) == .empty)
    }

    @Test("Группы других детекторов в решение одного не попадают")
    func otherDetectorsGroupsUntouched() {
        // A перешёл в Protected; группа «B-only» — только у реактивного B в Offline
        let decision = decide([
            (detector("A", groups: ["A-only"]), .protected),
            (detector("B", groups: ["B-only"]), .offline),
        ])
        #expect(decision.managed == ["A-only"])
    }

    @Test("Строгий детектор без вердикта (нет состояния) считается Offline и закрывает")
    func missingStateIsOffline() {
        let decision = GroupArbiter.decide(
            detectors: [detector("A", mode: .strict, groups: ["G"])], states: [:])
        #expect(decision.enable == ["G"])
    }
}
