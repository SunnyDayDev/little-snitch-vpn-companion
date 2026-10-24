import Testing

/// Сводное состояние для иконки и шапки (D11 design.md): худшее среди
/// включённых детекторов.
@Suite("AggregateStatus")
struct AggregateStatusTests {
    private func member(_ name: String, _ state: EgressState,
                        mode: ProtectionMode = .reactive,
                        enabled: Bool = true) -> AggregateStatus.Member {
        AggregateStatus.Member(id: DetectorID(name), isEnabled: enabled, mode: mode, state: state)
    }

    @Test("Порядок тяжести: Leak > Checking > Offline > Protected", arguments: [
        (EgressState.leak, EgressState.checking, EgressState.leak),
        (.leak, .offline, .leak),
        (.leak, .protected, .leak),
        (.checking, .offline, .checking),
        (.checking, .protected, .checking),
        (.offline, .protected, .offline),
        (.protected, .protected, .protected),
    ])
    func worstWins(first: EgressState, second: EgressState, expected: EgressState) {
        let forward = AggregateStatus.summarize([member("A", first), member("B", second)],
                                                isPaused: false)
        let backward = AggregateStatus.summarize([member("A", second), member("B", first)],
                                                 isPaused: false)
        #expect(forward.state == expected)
        #expect(backward.state == expected)
    }

    @Test("Виновник — детектор с худшим состоянием")
    func culpritIsWorstDetector() {
        let status = AggregateStatus.summarize([
            member("Основной", .protected),
            member("Через прокси", .leak),
        ], isPaused: false)
        #expect(status.state == .leak)
        #expect(status.culprit == DetectorID("Через прокси"))
    }

    @Test("При равной тяжести виновник — первый по порядку")
    func culpritIsFirstAmongEquals() {
        let status = AggregateStatus.summarize([
            member("A", .offline), member("B", .offline),
        ], isPaused: false)
        #expect(status.culprit == DetectorID("A"))
    }

    @Test("Все защищены — виновника нет")
    func allProtectedHasNoCulprit() {
        let status = AggregateStatus.summarize([
            member("A", .protected), member("B", .protected),
        ], isPaused: false)
        #expect(status.state == .protected)
        #expect(status.culprit == nil)
        #expect(!status.hasStrictClosed)
    }

    @Test("Выключенный детектор в сводку не входит")
    func disabledDetectorIgnored() {
        let status = AggregateStatus.summarize([
            member("A", .protected),
            member("B", .leak, enabled: false),
        ], isPaused: false)
        #expect(status.state == .protected)
    }

    @Test("Пауза мониторинга — Paused независимо от детекторов")
    func pausedWins() {
        let status = AggregateStatus.summarize([member("A", .leak)], isPaused: true)
        #expect(status.state == .paused)
        #expect(status.culprit == nil)
    }

    @Test("Без включённых детекторов — Offline с признаком «детекторов нет»")
    func noEnabledDetectors() {
        let none = AggregateStatus.summarize([], isPaused: false)
        #expect(none.state == .offline)
        #expect(!none.hasEnabledDetectors)

        let allDisabled = AggregateStatus.summarize([member("A", .leak, enabled: false)],
                                                    isPaused: false)
        #expect(allDisabled.state == .offline)
        #expect(!allDisabled.hasEnabledDetectors)
    }

    @Test("Строгий в Offline или Checking взводит признак «закрыто без утечки»", arguments: [
        EgressState.offline, .checking,
    ])
    func strictClosedFlag(state: EgressState) {
        let status = AggregateStatus.summarize([
            member("A", .protected),
            member("B", state, mode: .strict),
        ], isPaused: false)
        #expect(status.hasStrictClosed)
        #expect(status.culprit == DetectorID("B"))
    }

    @Test("Реактивный Offline признак не взводит: группы не тронуты")
    func reactiveOfflineIsNotClosed() {
        let status = AggregateStatus.summarize([member("A", .offline)], isPaused: false)
        #expect(status.state == .offline)
        #expect(!status.hasStrictClosed)
    }

    @Test("Paused отдельной машины вне общей паузы — без вердикта, как Offline")
    func memberPausedOutsidePauseIsOffline() {
        let status = AggregateStatus.summarize([
            member("A", .protected), member("B", .paused),
        ], isPaused: false)
        #expect(status.state == .offline)
        #expect(status.culprit == DetectorID("B"))
    }
}
