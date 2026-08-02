/// Таблица переходов §5 SPEC.md. Чистая и синхронная: таймеры, сеть и
/// вызовы helper живут в Application/Infrastructure, сюда приходят события,
/// отсюда уходят эффекты.
struct StateMachine {
    enum Event: Hashable {
        case started
        case probed(ProbeResult, trigger: ProbeTrigger)
        case tripwireBroken
        /// Путь изменился, сеть жива — событие приходит немедленно, до debounce:
        /// в строгом режиме закрыться нужно раньше, чем уйдёт проба.
        case pathShifted
        /// Путь изменился (после debounce) — пора пробовать.
        case pathChanged
        /// Сеть пропала (path unsatisfied): немедленный Offline без пробы.
        case pathDown
        /// Система засыпает. Сон НЕ гасит сеть (TCPKeepAlive держит стек), и
        /// path unsatisfied не приходит — это отдельная граница неопределённости.
        case systemWillSleep
        /// Система проснулась (полное или служебное пробуждение).
        case systemDidWake
        case userPaused
        case userResumed
        case userRequestedProbe
        /// Режим защиты переключён на лету; переходный reconcile делает
        /// координатор (цель не выражается парой «состояние + режим»).
        case modeSwitched
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
    /// Машина спит (от засыпания до ПОЛНОГО пробуждения, dark wake — тоже
    /// сон): в строгом режиме вердикт Protected не открывает группы.
    private var isAsleep = false
    /// Wi-Fi выключается один раз за эпизод недоступности helper.
    private var didEscalateDuringFailure = false
    /// Взводится на старте и при возобновлении: первый же вердикт обязан
    /// пройти через reconcile, даже если состояние не изменилось.
    private var needsReconcile = false

    init(state: EgressState = .offline) {
        self.state = state
    }

    mutating func handle(_ event: Event, mode: ProtectionMode = .reactive) -> [Effect] {
        switch event {
        case .started:
            needsReconcile = true
            guard mode == .strict else { return [.probeNow(.startup)] }
            // Строгий режим: закрыто до первого вердикта — сначала блок,
            // потом проба (§5, строка «старт»).
            state = .checking
            return [.reconcile(.checking), .probeNow(.startup)]

        case .probed(let result, let trigger):
            return handleProbe(result, trigger: trigger, mode: mode)

        case .tripwireBroken:
            guard state != .paused else { return [] }
            // Из устойчивого Protected проверка не закрывает превентивно:
            // события пути и обрывы растяжки часты, вердикт всё равно может
            // протухнуть сразу после проверки, а каждое закрытие — потерянные
            // запросы. Закрытым остаётся то, что уже закрыто (Offline/Checking).
            guard mode == .strict, state == .offline || state == .checking else {
                return [.probeNow(.tripwire)]
            }
            state = .checking
            return [.reconcile(.checking), .probeNow(.tripwire)]

        case .pathShifted:
            // Закрытие здесь — только удержание уже закрытого: сеть вернулась
            // после Offline → Checking, группы остаются включены до вердикта
            // Protected. Из устойчивого Protected смена пути не закрывает
            // (см. .tripwireBroken); Leak решает свежая проба.
            guard mode == .strict, state == .offline || state == .checking else { return [] }
            state = .checking
            return [.reconcile(.checking)]

        case .pathChanged:
            guard state != .paused else { return [] }
            return [.probeNow(.path)]

        case .pathDown:
            guard state != .paused else { return [] }
            consecutiveLeakProbes = 0
            lastDiagnosis = nil
            state = .offline
            // Реактивный: сети нет, утечки нет, группы не трогаем.
            return mode == .strict ? [.reconcile(.offline)] : []

        case .systemWillSleep:
            // Липкий флаг до полного пробуждения: уход из dark wake обратно
            // в сон системой НЕ сообщается (замер 2026-08-02: maintenance
            // sleep 16:02:22 без kIOMessageSystemWillSleep) — открытое в
            // dark wake осталось бы открытым на весь следующий отрезок сна.
            isAsleep = true
            // Засыпание — граница неопределённости (§5): вердикт Protected
            // протухает вместе с сессией, а проверить его во сне некому.
            // Реактивный: контракт «блок только при доказанной утечке» —
            // группы не трогаем, состояние не меняем.
            guard mode == .strict else { return [] }
            // Первый вердикт после пробуждения обязан пройти сверку, даже
            // если состояние не изменится: закрытие могло провалиться.
            needsReconcile = true
            // На паузе состояние сохраняется: закрытие здесь — идемпотентная
            // страховка от неудавшегося закрытия при постановке на паузу
            // (pausedCloseRetry во сне заморожен).
            guard state != .paused else { return [.reconcile(.paused)] }
            consecutiveLeakProbes = 0
            // Диагноз прошлой сессии после сна недостоверен, включая Leak:
            // закрыто в обоих случаях, Checking честнее.
            lastDiagnosis = nil
            state = .checking
            return [.reconcile(.checking)]

        case .systemDidWake:
            // kIOMessageSystemHasPoweredOn приходит только на полном
            // пробуждении (в dark wake — нет), поэтому здесь окно сна
            // закончилось достоверно.
            isAsleep = false
            guard state != .paused else { return [] }
            // Проба по событию пробуждения, не в надежде на событие пути:
            // в той же сети путь может не измениться вовсе.
            return [.probeNow(.power)]

        case .userRequestedProbe:
            return [.probeNow(.user)]

        case .modeSwitched:
            // Checking существует только в строгом режиме.
            if mode == .reactive, state == .checking { state = .offline }
            needsReconcile = true
            return state == .paused ? [] : [.probeNow(.user)]

        case .userPaused:
            state = .paused
            consecutiveLeakProbes = 0
            // Реактивный: пауза не снимает уже применённый блок, группы не
            // трогаем. Строгий: пауза закрывает; координатор обязан исполнить
            // эффект ДО остановки детектора.
            return mode == .strict ? [.reconcile(.paused)] : []

        case .userResumed:
            guard state == .paused else { return [] }
            needsReconcile = true
            guard mode == .strict else {
                state = .offline
                return [.probeNow(.user)]
            }
            // Группы уже закрыты паузой; сверка дешёвая и держит инвариант,
            // если их успели переключить руками в Little Snitch.
            state = .checking
            return [.reconcile(.checking), .probeNow(.user)]

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
                                      trigger: ProbeTrigger,
                                      mode: ProtectionMode) -> [Effect] {
        guard state != .paused else { return [] }

        switch result {
        case .protected(let trace):
            consecutiveLeakProbes = 0
            lastTrace = trace
            lastDiagnosis = nil
            // Во сне (dark wake) protected не открывает: повторное засыпание
            // из dark wake системой не сообщается, и открытое осталось бы
            // открытым на весь следующий отрезок сна. Открытие — только по
            // вердикту после полного пробуждения.
            if isAsleep, mode == .strict {
                state = .checking
                needsReconcile = true
                return []
            }
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
            let previous = state
            state = .offline
            // Реактивный: группы не трогаем — сети нет, утечки нет.
            guard mode == .strict else { return [] }
            // Строгий: offline закрыт. Сверка — при входе и на плановых
            // пробах (та же логика, что у Leak: helper мог умереть, группу
            // могли выключить руками).
            let verifies = trigger == .scheduled || trigger == .startup
            guard previous != .offline || needsReconcile || verifies else { return [] }
            needsReconcile = false
            return [.reconcile(.offline)]
        }
    }
}
