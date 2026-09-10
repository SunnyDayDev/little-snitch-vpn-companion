/// Жизненный цикл привилегированного helper (спека helper-lifecycle):
/// единственный владелец регистрации демона. Все пути к ней — онбординг,
/// авто-восстановление, проверка версии, кнопка, вотчдог — проходят через
/// этот актор, поэтому одновременно идёт не больше одной операции, а
/// ожидание ответа launchd измеряется бюджетом по часам, а не числом
/// попыток.
///
/// Почему не в `AppModel`: там каждая точка входа запускала свой `Task`,
/// потоки переустановки переключались на каждом `await`, и после замены
/// бандла (2026-09-09) кнопка полторы минуты отвечала «No such process»,
/// хотя новый демон стартовал ровно один раз — через 30 с после последнего
/// `register()`. Каждый лишний цикл сбрасывал ожидание BTM с нуля.

/// Состояние helper, единое для настроек, онбординга и поповера.
enum HelperState: Hashable, Sendable {
    enum Operation: Hashable, Sendable {
        case install
        case reinstall
        case remove
    }

    case notInstalled
    case notFound
    case awaitingApproval
    case working(Operation, startedAt: Instant)
    case ready(version: String)
    case stale(running: String, bundled: String)
    case silent(lastError: String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Демон отвечает — с ним можно разговаривать, даже если он устарел.
    var isResponsive: Bool {
        switch self {
        case .ready, .stale: true
        case .notInstalled, .notFound, .awaitingApproval, .working, .silent: false
        }
    }

    /// Версия работающего демона, если он ответил.
    var runningVersion: String? {
        switch self {
        case .ready(let version): version
        case .stale(let running, _): running
        default: nil
        }
    }
}

/// Политика ожидания ответа демона после регистрации. Бюджет считается по
/// часам: одна попытка стоит от нуля («No such process» у незагруженного
/// сервиса) до 6 с (XPC-таймаут у загруженного, но не одобренного).
struct HelperWaitPolicy: Hashable, Sendable {
    /// Один замер дал 30 с (2026-09-09), запас вдвое; ориентир —
    /// RunAtLoad-демон на загрузке BTM поднимает при uptime ~40 с.
    var budgetSeconds: Double = 60
    /// Первые секунды ответа почти наверняка нет, к концу минуты редкие
    /// опросы не мешают BTM. Последний интервал повторяется.
    var intervals: [Double] = [1, 2, 3, 5]
    /// `unregister()` завершается асинхронно; регистрировать поверх
    /// незавершённого снятия нельзя — снятие отменит регистрацию.
    var unregistrationBudgetSeconds: Double = 3
    var unregistrationStepSeconds: Double = 0.1
    /// Удаление ждёт фактического «не зарегистрирован» дольше: спешить некуда.
    var removalBudgetSeconds: Double = 10
    var removalStepSeconds: Double = 0.5
    /// После снятия регистрации job ещё выгружается из launchd: регистрация
    /// в этот момент падает с EPERM или остаётся мёртвой (2026-09-10).
    /// Ждём исчезновения job и выдерживаем паузу.
    var jobUnloadBudgetSeconds: Double = 15
    var jobUnloadStepSeconds: Double = 0.5
    var jobUnloadGraceSeconds: Double = 2
    /// `register()` может упасть временной ошибкой («Operation not
    /// permitted» сразу после снятия) — повторяем с нарастающим шагом.
    var registerRetryIntervals: [Double] = [0.5, 1, 2, 3]

    func interval(forAttempt attempt: Int) -> Double {
        intervals[min(max(attempt, 0), intervals.count - 1)]
    }
}

actor HelperLifecycle {
    private let registrar: any HelperRegistrar
    private let gateway: any RuleGroupGateway
    private let failsafe: any FailsafeSyncing
    private let facts: any HelperInstallFacts
    private let journal: any JournalStore
    private let clock: any Clock
    private let policy: HelperWaitPolicy
    private let onboardingCompleted: @Sendable () -> Bool

    private(set) var state: HelperState = .notInstalled
    private var observers: [AsyncStream<HelperState>.Continuation] = []
    private var current: Task<Void, Never>?
    /// Автоматические пути — не чаще раза за запуск: повторные полные циклы
    /// сбрасывали бы одобрение быстрее, чем пользователь успевает его дать.
    private var didAutoRestore = false
    private var didAutoUpdate = false
    private var didPromptApproval = false
    /// Операция, упёршаяся в одобрение: после одобрения ожидание
    /// продолжается под её именем.
    private var approvalOperation: HelperState.Operation = .install
    private var lastJournaledKey: String?

    init(registrar: any HelperRegistrar,
         gateway: any RuleGroupGateway,
         failsafe: any FailsafeSyncing,
         facts: any HelperInstallFacts,
         journal: any JournalStore,
         clock: any Clock,
         policy: HelperWaitPolicy = HelperWaitPolicy(),
         onboardingCompleted: @escaping @Sendable () -> Bool) {
        self.registrar = registrar
        self.gateway = gateway
        self.failsafe = failsafe
        self.facts = facts
        self.journal = journal
        self.clock = clock
        self.policy = policy
        self.onboardingCompleted = onboardingCompleted
    }

    // MARK: - Наблюдение

    /// Поток состояний: текущее сразу при подписке, дальше каждое изменение.
    /// Состояние «в работе» переиздаётся на каждом тике ожидания — так UI
    /// обновляет счётчик секунд без собственного таймера.
    func states() -> AsyncStream<HelperState> {
        let (stream, continuation) = AsyncStream.makeStream(of: HelperState.self)
        continuation.yield(state)
        observers.append(continuation)
        return stream
    }

    // MARK: - Точки входа

    /// Старт приложения: потерянная регистрация восстанавливается сама,
    /// если онбординг пройден и helper не удалял пользователь.
    func start() async {
        if registrar.status == .notRegistered,
           onboardingCompleted(),
           !facts.removedByUser,
           !didAutoRestore {
            didAutoRestore = true
            await journalEvent(.warning("регистрация helper потеряна — восстанавливаем"))
            await runOperation { await self.ladder(.install, registerFirst: true) }
            return
        }
        await refresh()
    }

    /// Вотчдог и открытие окон: переоценить состояние по фактам. Во время
    /// операции ничего не делает — ждать умеет сама операция.
    func refresh() async {
        guard current == nil else { return }
        await assess()
    }

    func install() async {
        await runOperation {
            self.facts.setRemovedByUser(false)
            await self.ladder(.install, registerFirst: true)
        }
    }

    /// Явная переустановка — сразу полный цикл: мягкая перерегистрация не
    /// лечит job, выгруженный вручную через `launchctl bootout`.
    func reinstall() async {
        await runOperation {
            let startedAt = await self.clock.now()
            await self.setState(.working(.reinstall, startedAt: startedAt))
            await self.journalEvent(.fact("переустанавливаем helper"))
            await self.prepareForCycle()
            guard await self.fullCycle() else { return }
            await self.finish(.reinstall,
                              outcome: await self.waitForAnswer(.reinstall, startedAt: await self.clock.now()))
        }
    }

    /// Удаление по запросу пользователя: без подтверждений в любом режиме,
    /// но с той же дисциплиной failsafe, что и переустановка.
    func remove(strictModeActive: Bool) async {
        await runOperation {
            let startedAt = await self.clock.now()
            await self.setState(.working(.remove, startedAt: startedAt))
            await self.journalEvent(.fact("удаляем helper по запросу пользователя"))
            await self.prepareForCycle()
            do {
                try await self.registrar.unregister()
            } catch {
                await self.journalEvent(.error("не удалось снять регистрацию helper: \(Self.describe(error))"))
                await self.assess()
                return
            }
            let unregistered = await self.waitForStatus(.notRegistered,
                                                         budget: self.policy.removalBudgetSeconds,
                                                         step: self.policy.removalStepSeconds)
            guard unregistered else {
                await self.journalEvent(.error("helper не снялся с регистрации за "
                    + "\(Int(self.policy.removalBudgetSeconds)) с — статус "
                    + "\(String(describing: self.registrar.status))"))
                await self.assess()
                return
            }
            self.facts.setRemovedByUser(true)
            if strictModeActive {
                await self.journalEvent(.warning("строгий режим без helper: группы Little Snitch "
                    + "не переключаются, страховки helper выключены"))
            }
            await self.transition(.notInstalled)
        }
    }

    func openApprovalSettings() async {
        await registrar.openApprovalSettings()
    }

    // MARK: - Оценка по фактам

    private func assess() async {
        switch registrar.status {
        case .notFound:
            await transition(.notFound)
        case .notRegistered:
            await transition(.notInstalled)
        case .requiresApproval:
            await enterAwaitingApproval(.install)
        case .enabled:
            do {
                let version = try await gateway.helperVersion()
                await settle(version: version, mayAutoUpdate: true)
            } catch {
                // Изнутри операции новую не начинают: она ждала бы сама себя.
                if current != nil {
                    await transition(.silent(lastError: Self.describe(error)))
                } else if case .awaitingApproval = state {
                    // Одобрение дали: ждём ответа без новой регистрации.
                    let operation = approvalOperation
                    await runOperation { await self.ladder(operation, registerFirst: false) }
                } else if !didAutoUpdate {
                    // Зарегистрирован, но молчит. Типичная причина — приложение
                    // пересобрано: launchd отказывается запускать бинарь, не
                    // совпадающий с подписью на момент регистрации (EX_CONFIG).
                    didAutoUpdate = true
                    await journalEvent(.warning("helper не отвечает — обновляем регистрацию"))
                    await runOperation { await self.ladder(.reinstall, registerFirst: true) }
                } else {
                    await transition(.silent(lastError: Self.describe(error)))
                }
            }
        }
    }

    /// Демон ответил: сверяем версию с бандлом. Устаревший демон обновляется
    /// автоматически один раз за запуск — launchd держит в памяти прежний
    /// бинарь и после обновления приложения.
    private func settle(version: String, mayAutoUpdate: Bool) async {
        let bundled = registrar.bundledVersion
        guard version != bundled else {
            await transition(.ready(version: version))
            return
        }
        guard mayAutoUpdate, !didAutoUpdate else {
            await transition(.stale(running: version, bundled: bundled))
            return
        }
        didAutoUpdate = true
        await journalEvent(.warning("helper устарел (\(version) вместо \(bundled)) — обновляем регистрацию"))
        if current == nil {
            await runOperation { await self.ladder(.reinstall, registerFirst: true) }
        } else {
            await ladder(.reinstall, registerFirst: true)
        }
    }

    // MARK: - Лестница эскалации

    private enum WaitOutcome {
        case answered(String)
        case approvalRequired
        case budgetExhausted(lastError: String)
    }

    /// Автоматический путь: регистрация поверх текущей → бюджет → не больше
    /// одного полного цикла → бюджет → «молчит». Полный цикл нужен в двух
    /// случаях: демон не ответил за бюджет, либо ответил старой версией —
    /// `register()` поверх обновляет launch constraint, но процесс в памяти
    /// не перезапускает (2026-09-10: старый демон отвечал сразу же).
    /// `registerFirst: false` — ожидание после обнаруженного одобрения,
    /// регистрировать заново нечего.
    private func ladder(_ operation: HelperState.Operation, registerFirst: Bool) async {
        let startedAt = await clock.now()
        await setState(.working(operation, startedAt: startedAt))
        await journalEvent(.fact(Self.operationStartText(operation, registerFirst: registerFirst)))
        await prepareForCycle()
        if registerFirst {
            guard await register() else { return }
        }
        var outcome = await waitForAnswer(operation, startedAt: startedAt)
        if let reason = fullCycleReason(for: outcome) {
            await journalEvent(.warning(reason))
            guard await fullCycle() else { return }
            outcome = await waitForAnswer(operation, startedAt: await clock.now())
        }
        await finish(operation, outcome: outcome)
    }

    private func fullCycleReason(for outcome: WaitOutcome) -> String? {
        switch outcome {
        case .budgetExhausted:
            "helper не ответил за \(Int(policy.budgetSeconds)) с — полный цикл снятия и регистрации"
        case .answered(let version) where version != registrar.bundledVersion:
            "старый helper (\(version)) остался в памяти — перезапускаем полным циклом"
        case .answered, .approvalRequired:
            nil
        }
    }

    /// Итог лестницы. Автоматическое обновление по версии здесь не
    /// запускается: свой полный цикл лестница уже сделала.
    private func finish(_ operation: HelperState.Operation, outcome: WaitOutcome) async {
        switch outcome {
        case .answered(let version):
            await settle(version: version, mayAutoUpdate: false)
        case .approvalRequired:
            await enterAwaitingApproval(operation)
        case .budgetExhausted(let lastError):
            await journalEvent(.error(lastError))
            await transition(.silent(lastError: lastError))
        }
    }

    /// Опрос версии с нарастающим интервалом в пределах бюджета. Статус
    /// «ждёт одобрения» прерывает ожидание: демон не поднимется, пока
    /// пользователь не включит объект входа.
    private func waitForAnswer(_ operation: HelperState.Operation,
                               startedAt: Instant) async -> WaitOutcome {
        var attempt = 0
        var lastError = "нет ответа helper"
        while true {
            if registrar.status == .requiresApproval { return .approvalRequired }
            do {
                return .answered(try await gateway.helperVersion())
            } catch {
                lastError = Self.describe(error)
            }
            let elapsed = await clock.now().seconds(since: startedAt)
            if elapsed >= policy.budgetSeconds {
                return .budgetExhausted(lastError: lastError)
            }
            await clock.sleep(seconds: policy.interval(forAttempt: attempt))
            attempt += 1
            await gateway.resetConnection()
            // Тот же `startedAt`: подписчики пересчитывают прошедшее время.
            await setState(.working(operation, startedAt: startedAt))
        }
    }

    /// Регистрация с повторами: сразу после снятия `register()` падает
    /// временной «Operation not permitted», а через несколько секунд
    /// проходит. Окончательный отказ — ошибка в журнал и оценка по фактам.
    private func register() async -> Bool {
        var lastError: any Error = RuleGroupGatewayError.helperUnavailable("register не вызывался")
        for (attempt, interval) in (policy.registerRetryIntervals + [0]).enumerated() {
            do {
                try registrar.register()
                return true
            } catch {
                lastError = error
            }
            guard attempt < policy.registerRetryIntervals.count else { break }
            await journalEvent(.warning("register не прошёл (\(Self.describe(lastError))) — "
                + "повтор через \(interval) с"))
            await clock.sleep(seconds: interval)
        }
        await journalEvent(.error("не удалось зарегистрировать helper: \(Self.describe(lastError))"))
        await assess()
        return false
    }

    /// Полный цикл: снятие с ожиданием фактического «не зарегистрирован» и
    /// выгрузки job из launchd, пауза, затем регистрация. Регистрация раньше
    /// выгрузки либо падает с EPERM, либо остаётся мёртвой: статус `enabled`,
    /// а демон не поднимается (2026-09-10). Если снятие не завершилось за
    /// бюджет — регистрируем поверх, как делал `HelperInstaller.reinstall()`.
    private func fullCycle() async -> Bool {
        try? await registrar.unregister()
        let unregistered = await waitForStatus(.notRegistered,
                                               budget: policy.unregistrationBudgetSeconds,
                                               step: policy.unregistrationStepSeconds)
        if !unregistered {
            await journalEvent(.warning("helper не снялся с регистрации за "
                + "\(Int(policy.unregistrationBudgetSeconds)) с — регистрируем поверх"))
        } else {
            await waitForJobUnloaded()
        }
        return await register()
    }

    private func waitForJobUnloaded() async {
        let began = await clock.now()
        while let loaded = await registrar.isJobLoaded(), loaded {
            if await clock.now().seconds(since: began) >= policy.jobUnloadBudgetSeconds {
                await journalEvent(.warning("job helper не выгрузился из launchd за "
                    + "\(Int(policy.jobUnloadBudgetSeconds)) с — регистрируем поверх"))
                return
            }
            await clock.sleep(seconds: policy.jobUnloadStepSeconds)
        }
        if policy.jobUnloadGraceSeconds > 0 {
            await clock.sleep(seconds: policy.jobUnloadGraceSeconds)
        }
    }

    private func waitForStatus(_ expected: HelperRegistrationStatus,
                               budget: Double,
                               step: Double) async -> Bool {
        let began = await clock.now()
        while registrar.status != expected {
            if await clock.now().seconds(since: began) >= budget { return false }
            await clock.sleep(seconds: step)
        }
        return true
    }

    /// Любой цикл рвёт XPC-соединения: супервизию helper снимаем заранее,
    /// чтобы dead-man's switch не принял разрыв за смерть приложения (D5).
    private func prepareForCycle() async {
        try? await failsafe.syncFailsafe(.inactive)
        await gateway.resetConnection()
    }

    private func enterAwaitingApproval(_ operation: HelperState.Operation) async {
        approvalOperation = operation
        await transition(.awaitingApproval)
        // Пока macOS ждёт одобрения объекта входа, демон не запускается
        // вовсе, а сам пользователь про этот шаг не догадается.
        guard !didPromptApproval else { return }
        didPromptApproval = true
        await registrar.openApprovalSettings()
    }

    // MARK: - Одна операция за раз

    /// Запрос во время идущей операции присоединяется к ней и не начинает
    /// новый цикл снятия или регистрации.
    private func runOperation(_ body: @escaping @Sendable () async -> Void) async {
        if let current {
            await current.value
            return
        }
        let task = Task { await body() }
        current = task
        await task.value
        current = nil
    }

    // MARK: - Состояние и журнал

    private func setState(_ new: HelperState) async {
        state = new
        for observer in observers { observer.yield(new) }
    }

    /// Переход в устойчивое состояние: одна запись журнала на переход.
    private func transition(_ new: HelperState) async {
        await setState(new)
        let key = Self.journalKey(new)
        guard key != lastJournaledKey else { return }
        lastJournaledKey = key
        switch new {
        case .ready(let version):
            await journalEvent(.fact("helper подключён · v\(version)"))
        case .notInstalled:
            await journalEvent(.fact("helper не установлен"))
        case .notFound:
            await journalEvent(.error("helper не найден в бандле приложения — сборка повреждена"))
        case .awaitingApproval:
            await journalEvent(.warning("helper ждёт одобрения: Системные настройки → Основные "
                + "→ Объекты входа → включить Little Snitch VPN Companion"))
        case .stale(let running, let bundled):
            await journalEvent(.warning("helper устарел (\(running) вместо \(bundled)) — "
                + "нужна переустановка"))
        case .silent:
            await journalEvent(.warning("helper зарегистрирован, но не отвечает — "
                + "переустановите его вручную"))
        case .working:
            break
        }
    }

    private static func journalKey(_ state: HelperState) -> String {
        switch state {
        case .notInstalled: "notInstalled"
        case .notFound: "notFound"
        case .awaitingApproval: "awaitingApproval"
        case .working: "working"
        case .ready(let version): "ready:\(version)"
        case .stale(let running, let bundled): "stale:\(running):\(bundled)"
        case .silent: "silent"
        }
    }

    private static func operationStartText(_ operation: HelperState.Operation,
                                           registerFirst: Bool) -> String {
        switch operation {
        case .install: registerFirst ? "устанавливаем helper" : "helper одобрен — ждём ответа"
        case .reinstall: registerFirst ? "обновляем регистрацию helper" : "helper одобрен — ждём ответа"
        case .remove: "удаляем helper"
        }
    }

    private func journalEvent(_ kind: JournalEvent.Kind) async {
        await journal.append(JournalEvent(time: await clock.now(), trigger: .helper, kind: kind))
    }

    private static func describe(_ error: any Error) -> String {
        (error as? RuleGroupGatewayError)?.message ?? String(describing: error)
    }
}
