/// Таблица переходов §5 SPEC.md. Чистая и синхронная: таймеры, сеть и
/// вызовы helper живут в Application/Infrastructure, сюда приходят события,
/// отсюда уходят эффекты.
struct StateMachine {
    enum Event: Hashable {
        case started
        case probed(ProbeResult, trigger: ProbeTrigger)
        case tripwireBroken
        case pathChanged
        case userPaused
        case userResumed
        case userRequestedProbe
        case helperFailed(String)
        case helperRecovered
    }

    enum Effect: Hashable {
        case probeNow(ProbeTrigger)
        /// Утечка-кандидат замечена: нужна подтверждающая проба через 2–3 с.
        case scheduleLeakConfirmation
        /// Привести группы LS к целевому набору для состояния.
        case reconcile(EgressState)
        case notifyLeak(LeakDiagnosis)
        case notifyProtected
        case notifyHelperFailure(String)
        /// Утечка подтверждена, а helper не работает — выключить Wi-Fi (ФТ-9).
        case escalate
    }

    private(set) var state: EgressState = .offline
    private(set) var helperUnavailable = false
    private(set) var lastTrace: BeaconTrace?
    private(set) var lastDiagnosis: LeakDiagnosis?

    private var consecutiveLeakProbes = 0
    /// Wi-Fi выключается один раз за эпизод недоступности helper.
    private var didEscalateDuringFailure = false
    /// Взводится на старте и при возобновлении: первый же вердикт обязан
    /// пройти через reconcile, даже если состояние не изменилось.
    private var needsReconcile = false

    init(state: EgressState = .offline) {
        self.state = state
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .started:
            needsReconcile = true
            return [.probeNow(.startup)]

        case .probed(let result, let trigger):
            return handleProbe(result, trigger: trigger)

        case .tripwireBroken:
            guard state != .paused else { return [] }
            return [.probeNow(.tripwire)]

        case .pathChanged:
            guard state != .paused else { return [] }
            return [.probeNow(.path)]

        case .userRequestedProbe:
            return [.probeNow(.user)]

        case .userPaused:
            // Группы не трогаем: пауза не снимает уже применённый блок.
            state = .paused
            consecutiveLeakProbes = 0
            return []

        case .userResumed:
            guard state == .paused else { return [] }
            state = .offline
            needsReconcile = true
            return [.probeNow(.user)]

        case .helperFailed(let message):
            let wasUnavailable = helperUnavailable
            helperUnavailable = true
            // Провалившийся reconcile обязан быть повторён: иначе блок остался
            // бы включённым (или невключённым) до следующего перехода, которого
            // может не случиться никогда.
            needsReconcile = true

            var effects: [Effect] = []
            // Об отказе сообщаем один раз за эпизод: сверка повторяется каждой
            // пробой, и без этого пользователь получал бы шквал одинаковых
            // уведомлений, пока helper не починится.
            if !wasUnavailable { effects.append(.notifyHelperFailure(message)) }
            // Эскалация — тоже один раз за эпизод, но привязана к Leak
            // отдельно: helper мог отказать ещё в Protected, а утечка
            // случиться позже — тогда выключать Wi-Fi нужно именно тогда.
            if state == .leak, !didEscalateDuringFailure {
                didEscalateDuringFailure = true
                effects.append(.escalate)
            }
            return effects

        case .helperRecovered:
            helperUnavailable = false
            didEscalateDuringFailure = false
            return []
        }
    }

    private mutating func handleProbe(_ result: ProbeResult,
                                      trigger: ProbeTrigger) -> [Effect] {
        guard state != .paused else { return [] }

        switch result {
        case .protected(let trace):
            consecutiveLeakProbes = 0
            lastTrace = trace
            lastDiagnosis = nil
            let previous = state
            state = .protected
            var effects: [Effect] = []
            if previous != .protected || needsReconcile {
                needsReconcile = false
                effects.append(.reconcile(.protected))
            }
            if previous == .leak { effects.append(.notifyProtected) }
            return effects

        case .leakCandidate(let trace, let diagnosis):
            lastTrace = trace
            lastDiagnosis = diagnosis
            consecutiveLeakProbes += 1

            if state == .leak {
                // Уже заблокировано. Плановая проба всё равно сверяет группы:
                // helper мог умереть после применения блока, а пользователь —
                // выключить группу руками в Little Snitch. Без этой сверки
                // отказ helper во время установленного Leak не обнаружился бы
                // вовсе, и эскалация (ФТ-9) не сработала бы.
                let verifies = trigger == .scheduled || trigger == .startup
                guard needsReconcile || verifies else { return [] }
                needsReconcile = false
                return [.reconcile(.leak)]
            }
            // Утечка фиксируется только со второй пробы подряд (§4.3).
            guard consecutiveLeakProbes >= 2 else { return [.scheduleLeakConfirmation] }

            state = .leak
            needsReconcile = false
            return [.reconcile(.leak), .notifyLeak(diagnosis)]

        case .offline:
            consecutiveLeakProbes = 0
            lastDiagnosis = nil
            // Группы не трогаем: сети нет, утечки нет.
            state = .offline
            return []
        }
    }
}
