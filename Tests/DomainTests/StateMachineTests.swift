import Testing

/// Таблица §5 SPEC.md — каждая строка покрыта минимум одним тестом.
@Suite("StateMachine")
struct StateMachineTests {
    private let egress = IPAddress("203.0.113.40")!
    private let cloudflare = IPAddress("2a09:bac5::3f")!

    private var leak: ProbeResult {
        .leakCandidate(BeaconTrace(ip: egress, warp: .off), .foreignEgress)
    }

    private var protected: ProbeResult {
        .protected(BeaconTrace(ip: cloudflare, warp: .on))
    }

    private func machine(in state: EgressState) -> StateMachine {
        var machine = StateMachine(state: state)
        // Съедаем стартовый reconcile, чтобы тесты видели только свои эффекты
        if state != .paused {
            _ = machine.handle(.probed(state == .leak ? leak : protected, trigger: .startup))
            if state == .leak {
                _ = machine.handle(.probed(leak, trigger: .confirmation))
            }
        }
        return machine
    }

    // MARK: - Старт

    @Test("Старт приложения → немедленная проба")
    func startTriggersProbe() {
        var machine = StateMachine()
        #expect(machine.handle(.started) == [.probeNow(.startup)])
    }

    @Test("Первый вердикт после старта всегда идёт через reconcile")
    func startReconciles() {
        var machine = StateMachine()
        _ = machine.handle(.started)
        let effects = machine.handle(.probed(protected, trigger: .startup))
        #expect(effects == [.reconcile(.protected)])
        #expect(machine.state == .protected)
    }

    // MARK: - Утечка и подтверждение

    @Test("Одна leak-проба не переводит в Leak — нужна подтверждающая")
    func singleLeakProbeIsNotEnough() {
        var machine = machine(in: .protected)
        let effects = machine.handle(.probed(leak, trigger: .scheduled))
        #expect(effects == [.scheduleLeakConfirmation])
        #expect(machine.state == .protected)
    }

    @Test("Две leak-пробы подряд → Leak, reconcile и уведомление")
    func confirmedLeak() {
        var machine = machine(in: .protected)
        _ = machine.handle(.probed(leak, trigger: .scheduled))
        let effects = machine.handle(.probed(leak, trigger: .confirmation))
        #expect(effects == [.reconcile(.leak), .notifyLeak(.foreignEgress)])
        #expect(machine.state == .leak)
    }

    @Test("Разовый ложняк не приводит к Leak")
    func falsePositiveIgnored() {
        var machine = machine(in: .protected)
        _ = machine.handle(.probed(leak, trigger: .scheduled))
        let effects = machine.handle(.probed(protected, trigger: .confirmation))
        #expect(machine.state == .protected)
        #expect(effects.isEmpty)
    }

    @Test("Повторная утечка в состоянии Leak не порождает переходов и уведомлений")
    func leakStaysLeak() {
        var machine = machine(in: .leak)
        #expect(machine.state == .leak)
        // Подтверждающая проба ничего не делает
        #expect(machine.handle(.probed(leak, trigger: .confirmation)).isEmpty)
        #expect(machine.state == .leak)
    }

    /// Иначе отказ helper, случившийся уже после применения блока, никогда не
    /// обнаружился бы: переходов больше нет, а значит нет и вызовов helper —
    /// и эскалация (ФТ-9) не срабатывает.
    @Test("Плановая проба в Leak сверяет группы заново")
    func scheduledProbeVerifiesGroupsDuringLeak() {
        var machine = machine(in: .leak)
        #expect(machine.handle(.probed(leak, trigger: .scheduled)) == [.reconcile(.leak)])
        #expect(machine.state == .leak)
    }

    /// Провалившийся reconcile обязан быть повторён — иначе блок остался бы
    /// включённым (или невключённым) до следующего перехода.
    @Test("После отказа helper reconcile повторяется на следующей пробе")
    func failedReconcileIsRetried() {
        var machine = machine(in: .protected)
        _ = machine.handle(.helperFailed("нет соединения"))
        let effects = machine.handle(.probed(protected, trigger: .confirmation))
        #expect(effects == [.reconcile(.protected)])
    }

    @Test("Утечка из Offline тоже требует подтверждения")
    func leakFromOfflineNeedsConfirmation() {
        var machine = StateMachine(state: .offline)
        #expect(machine.handle(.probed(leak, trigger: .path)) == [.scheduleLeakConfirmation])
        let effects = machine.handle(.probed(leak, trigger: .confirmation))
        #expect(effects.contains(.reconcile(.leak)))
        #expect(machine.state == .leak)
    }

    // MARK: - Восстановление

    @Test("Leak → Protected: reconcile и уведомление о восстановлении")
    func recoveryFromLeak() {
        var machine = machine(in: .leak)
        let effects = machine.handle(.probed(protected, trigger: .scheduled))
        #expect(effects == [.reconcile(.protected), .notifyProtected])
        #expect(machine.state == .protected)
    }

    @Test("Protected → Protected не порождает лишних действий")
    func steadyProtectedIsQuiet() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.probed(protected, trigger: .scheduled)).isEmpty)
    }

    // MARK: - Offline

    @Test("Пробы перестали отвечать → Offline, группы не трогаем")
    func probesStopAnswering() {
        var machine = machine(in: .leak)
        let effects = machine.handle(.probed(.offline(.timeout), trigger: .scheduled))
        #expect(machine.state == .offline)
        #expect(effects.isEmpty)
    }

    @Test("Offline → ответ маяка возвращает состояние с reconcile")
    func recoveryFromOffline() {
        var machine = machine(in: .protected)
        _ = machine.handle(.probed(.offline(.networkFailure), trigger: .path))
        let effects = machine.handle(.probed(protected, trigger: .path))
        #expect(effects == [.reconcile(.protected)])
        #expect(machine.state == .protected)
    }

    @Test("Offline сбрасывает счётчик подтверждения утечки")
    func offlineResetsLeakCounter() {
        var machine = machine(in: .protected)
        _ = machine.handle(.probed(leak, trigger: .scheduled))
        _ = machine.handle(.probed(.offline(.timeout), trigger: .tripwire))
        // После офлайна счёт начинается заново: одной пробы снова мало
        #expect(machine.handle(.probed(leak, trigger: .path)) == [.scheduleLeakConfirmation])
        #expect(machine.state == .offline)
    }

    // MARK: - Триггеры немедленной пробы

    @Test("Обрыв растяжки → немедленная проба")
    func tripwireTriggersProbe() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.tripwireBroken) == [.probeNow(.tripwire)])
    }

    @Test("Событие сетевого пути → немедленная проба")
    func pathChangeTriggersProbe() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.pathChanged) == [.probeNow(.path)])
    }

    @Test("Сдвиг пути в реактивном режиме — тишина до вердикта")
    func pathShiftIsQuietInReactive() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.pathShifted).isEmpty)
        #expect(machine.state == .protected)
    }

    @Test("Пропажа сети → немедленный Offline, группы не трогаем")
    func pathDownGoesOfflineImmediately() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.pathDown).isEmpty)
        #expect(machine.state == .offline)
    }

    @Test("Пропажа сети сбрасывает счётчик подтверждения утечки")
    func pathDownResetsLeakCounter() {
        var machine = machine(in: .protected)
        _ = machine.handle(.probed(leak, trigger: .scheduled))
        _ = machine.handle(.pathDown)
        #expect(machine.handle(.probed(leak, trigger: .path)) == [.scheduleLeakConfirmation])
    }

    // MARK: - Пауза

    @Test("Пауза: состояние Paused, группы не трогаем")
    func pauseKeepsGroups() {
        var machine = machine(in: .leak)
        #expect(machine.handle(.userPaused).isEmpty)
        #expect(machine.state == .paused)
    }

    @Test("В паузе события детектора игнорируются")
    func pausedIgnoresDetector() {
        var machine = machine(in: .protected)
        _ = machine.handle(.userPaused)
        #expect(machine.handle(.tripwireBroken).isEmpty)
        #expect(machine.handle(.pathChanged).isEmpty)
        #expect(machine.handle(.probed(leak, trigger: .scheduled)).isEmpty)
        #expect(machine.state == .paused)
    }

    @Test("Возобновление → немедленная проба и reconcile по результату")
    func resumeProbesAndReconciles() {
        var machine = machine(in: .protected)
        _ = machine.handle(.userPaused)
        #expect(machine.handle(.userResumed) == [.probeNow(.user)])
        let effects = machine.handle(.probed(protected, trigger: .user))
        #expect(effects == [.reconcile(.protected)])
    }

    @Test("Пауза → утечка → возобновление: блок применяется после подтверждения")
    func pausedLeakAppliedAfterResume() {
        var machine = machine(in: .protected)
        _ = machine.handle(.userPaused)
        _ = machine.handle(.probed(leak, trigger: .scheduled))
        #expect(machine.state == .paused)

        _ = machine.handle(.userResumed)
        _ = machine.handle(.probed(leak, trigger: .user))
        let effects = machine.handle(.probed(leak, trigger: .confirmation))
        #expect(effects == [.reconcile(.leak), .notifyLeak(.foreignEgress)])
        #expect(machine.state == .leak)
    }

    // MARK: - Helper

    @Test("Отказ helper при Leak → уведомление и эскалация")
    func helperFailureDuringLeakEscalates() {
        var machine = machine(in: .leak)
        let effects = machine.handle(.helperFailed("littlesnitch timeout"))
        #expect(effects == [.notifyHelperFailure("littlesnitch timeout"), .escalate])
        #expect(machine.helperUnavailable)
        #expect(machine.state == .leak)
    }

    @Test("Отказ helper вне Leak не эскалирует")
    func helperFailureOutsideLeakDoesNotEscalate() {
        var machine = machine(in: .protected)
        let effects = machine.handle(.helperFailed("no CLI"))
        #expect(effects == [.notifyHelperFailure("no CLI")])
        #expect(machine.state == .protected)
    }

    @Test("Восстановление helper снимает флаг")
    func helperRecoveryClearsFlag() {
        var machine = machine(in: .leak)
        _ = machine.handle(.helperFailed("boom"))
        _ = machine.handle(.helperRecovered)
        #expect(!machine.helperUnavailable)
    }

    /// Сверка повторяется каждой пробой, поэтому без дедупликации отказ helper
    /// давал шквал одинаковых уведомлений (замечено на приёмке, сценарий 8).
    @Test("Об отказе helper сообщаем один раз за эпизод")
    func helperFailureNotifiesOnce() {
        var machine = machine(in: .protected)
        #expect(machine.handle(.helperFailed("нет связи")) == [.notifyHelperFailure("нет связи")])
        #expect(machine.handle(.helperFailed("нет связи")).isEmpty)
        #expect(machine.handle(.helperFailed("другая причина")).isEmpty)

        // После восстановления новый отказ снова заслуживает уведомления
        _ = machine.handle(.helperRecovered)
        #expect(machine.handle(.helperFailed("снова")) == [.notifyHelperFailure("снова")])
    }

    @Test("Wi-Fi выключается один раз за эпизод, а не на каждой пробе")
    func escalatesOncePerEpisode() {
        var machine = machine(in: .leak)
        #expect(machine.handle(.helperFailed("boom"))
            == [.notifyHelperFailure("boom"), .escalate])
        #expect(machine.handle(.helperFailed("boom")).isEmpty)
    }

    /// helper мог отказать ещё в Protected, а утечка случиться позже —
    /// эскалация обязана сработать именно тогда, а не потеряться.
    @Test("Отказ до утечки: эскалация срабатывает, когда наступает Leak")
    func escalatesWhenLeakComesAfterFailure() {
        var machine = machine(in: .protected)
        _ = machine.handle(.helperFailed("нет связи"))

        _ = machine.handle(.probed(leak, trigger: .scheduled))
        _ = machine.handle(.probed(leak, trigger: .confirmation))
        #expect(machine.state == .leak)

        #expect(machine.handle(.helperFailed("нет связи")) == [.escalate])
    }

    @Test("Диагноз утечки сохраняется для UI и журнала")
    func keepsDiagnosis() {
        let server = IPAddress("198.51.100.10")!
        var machine = machine(in: .protected)
        let serverLeak = ProbeResult.leakCandidate(BeaconTrace(ip: server, warp: .on),
                                                   .forbiddenServer(server))
        _ = machine.handle(.probed(serverLeak, trigger: .scheduled))
        _ = machine.handle(.probed(serverLeak, trigger: .confirmation))
        #expect(machine.lastDiagnosis == .forbiddenServer(server))
        #expect(machine.lastTrace?.ip == server)
    }
}

/// Строгий режим (§5): открыто ⇔ доказанный Protected. Каждая
/// режимозависимая строка таблицы переходов — в обоих режимах.
@Suite("StateMachine — строгий режим")
struct StrictStateMachineTests {
    private let egress = IPAddress("203.0.113.40")!
    private let cloudflare = IPAddress("2a09:bac5::3f")!

    private var leak: ProbeResult {
        .leakCandidate(BeaconTrace(ip: egress, warp: .off), .foreignEgress)
    }

    private var protected: ProbeResult {
        .protected(BeaconTrace(ip: cloudflare, warp: .on))
    }

    /// Машина после старта и первого Protected-вердикта: группы открыты.
    private func protectedMachine() -> StateMachine {
        var machine = StateMachine()
        _ = machine.handle(.started, mode: .strict)
        _ = machine.handle(.probed(protected, trigger: .startup), mode: .strict)
        return machine
    }

    @Test("Старт: сначала закрыть, потом проба")
    func startClosesFirst() {
        var machine = StateMachine()
        let effects = machine.handle(.started, mode: .strict)
        #expect(effects == [.reconcile(.checking), .probeNow(.startup)])
        #expect(machine.state == .checking)
    }

    @Test("Protected-вердикт — единственная дверь в «открыто»")
    func onlyProtectedOpens() {
        var machine = StateMachine()
        _ = machine.handle(.started, mode: .strict)
        let effects = machine.handle(.probed(protected, trigger: .startup), mode: .strict)
        #expect(effects == [.reconcile(.protected)])
        #expect(machine.state == .protected)
    }

    @Test("Возврат сети из Offline: Checking, группы остаются закрыты")
    func pathShiftFromOfflineStaysClosed() {
        var machine = protectedMachine()
        _ = machine.handle(.pathDown, mode: .strict)
        #expect(machine.handle(.pathShifted, mode: .strict) == [.reconcile(.checking)])
        #expect(machine.state == .checking)
        #expect(machine.handle(.pathChanged, mode: .strict) == [.probeNow(.path)])
    }

    @Test("Проверка из открытого состояния не закрывает: вердикт решает")
    func checksFromProtectedStayOpen() {
        // События пути и обрывы растяжки часты; превентивное закрытие на
        // каждую проверку — ощутимые потери запросов при иллюзорной гарантии.
        var machine = protectedMachine()
        #expect(machine.handle(.tripwireBroken, mode: .strict) == [.probeNow(.tripwire)])
        #expect(machine.state == .protected)
        #expect(machine.handle(.pathShifted, mode: .strict).isEmpty)
        #expect(machine.state == .protected)
        // Offline-вердикт проверки закрывает
        #expect(machine.handle(.probed(.offline(.timeout), trigger: .path), mode: .strict)
            == [.reconcile(.offline)])
    }

    @Test("Обрыв растяжки при закрытом состоянии держит закрыто")
    func tripwireBreakWhileClosedStaysClosed() {
        var machine = protectedMachine()
        _ = machine.handle(.pathDown, mode: .strict)
        let effects = machine.handle(.tripwireBroken, mode: .strict)
        #expect(effects == [.reconcile(.checking), .probeNow(.tripwire)])
        #expect(machine.state == .checking)
    }

    @Test("Сдвиг пути при Leak не размывает статус утечки")
    func pathShiftKeepsLeak() {
        var machine = protectedMachine()
        _ = machine.handle(.probed(leak, trigger: .scheduled), mode: .strict)
        _ = machine.handle(.probed(leak, trigger: .confirmation), mode: .strict)
        #expect(machine.state == .leak)
        #expect(machine.handle(.pathShifted, mode: .strict).isEmpty)
        #expect(machine.handle(.tripwireBroken, mode: .strict) == [.probeNow(.tripwire)])
        #expect(machine.state == .leak)
    }

    @Test("Пропажа сети → Offline с закрывающим reconcile")
    func pathDownCloses() {
        var machine = protectedMachine()
        #expect(machine.handle(.pathDown, mode: .strict) == [.reconcile(.offline)])
        #expect(machine.state == .offline)
    }

    @Test("Offline-вердикт закрывает, плановая проба сверяет заново")
    func offlineVerdictClosesAndVerifies() {
        var machine = protectedMachine()
        let entering = machine.handle(.probed(.offline(.timeout), trigger: .tripwire),
                                      mode: .strict)
        #expect(entering == [.reconcile(.offline)])
        // Повторный офлайн без планового триггера — тихо
        #expect(machine.handle(.probed(.offline(.timeout), trigger: .path),
                               mode: .strict).isEmpty)
        // Плановая проба сверяет группы, как в Leak
        #expect(machine.handle(.probed(.offline(.timeout), trigger: .scheduled),
                               mode: .strict) == [.reconcile(.offline)])
    }

    @Test("Сеть вернулась: Checking, открытие только по Protected")
    func recoveryRequiresProtectedVerdict() {
        var machine = protectedMachine()
        _ = machine.handle(.pathDown, mode: .strict)
        #expect(machine.handle(.pathShifted, mode: .strict) == [.reconcile(.checking)])
        #expect(machine.state == .checking)
        // Первый leak-кандидат не открывает и не меняет состояние
        #expect(machine.handle(.probed(leak, trigger: .path), mode: .strict)
            == [.scheduleLeakConfirmation])
        #expect(machine.state == .checking)
        // Protected открывает
        #expect(machine.handle(.probed(protected, trigger: .confirmation), mode: .strict)
            == [.reconcile(.protected)])
        #expect(machine.state == .protected)
    }

    @Test("Подтверждённая утечка из Checking")
    func confirmedLeakFromChecking() {
        var machine = protectedMachine()
        _ = machine.handle(.pathDown, mode: .strict)
        _ = machine.handle(.pathShifted, mode: .strict)
        #expect(machine.state == .checking)
        _ = machine.handle(.probed(leak, trigger: .path), mode: .strict)
        let effects = machine.handle(.probed(leak, trigger: .confirmation), mode: .strict)
        #expect(effects == [.reconcile(.leak), .notifyLeak(.foreignEgress)])
        #expect(machine.state == .leak)
    }

    @Test("Пауза закрывает группы")
    func pauseCloses() {
        var machine = protectedMachine()
        #expect(machine.handle(.userPaused, mode: .strict) == [.reconcile(.paused)])
        #expect(machine.state == .paused)
    }

    @Test("Возобновление: Checking, сверка и открытие только после вердикта")
    func resumeStaysClosedUntilVerdict() {
        var machine = protectedMachine()
        _ = machine.handle(.userPaused, mode: .strict)
        let effects = machine.handle(.userResumed, mode: .strict)
        #expect(effects == [.reconcile(.checking), .probeNow(.user)])
        #expect(machine.state == .checking)
        #expect(machine.handle(.probed(protected, trigger: .user), mode: .strict)
            == [.reconcile(.protected)])
    }

    @Test("Отказ helper при Offline/Checking не эскалирует")
    func helperFailureWhileClosedDoesNotEscalate() {
        var machine = protectedMachine()
        _ = machine.handle(.pathDown, mode: .strict)
        let effects = machine.handle(.helperFailed("нет связи"), mode: .strict)
        #expect(effects == [.notifyHelperFailure("нет связи")])
    }
}
