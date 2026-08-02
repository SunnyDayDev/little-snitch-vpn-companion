/// Снимок состояния для UI: всё, что показывают поповер и окна.
struct MonitoringSnapshot: Hashable, Sendable {
    var state: EgressState = .offline
    var trace: BeaconTrace?
    var diagnosis: LeakDiagnosis?
    var lastCheck: Instant?
    var lastTrigger: ProbeTrigger?
    var helperUnavailable = false
    var directRuIP: IPAddress?
    var directRuIPUpdated: Instant?
    var path: NetworkPathInfo?
    /// Группы, фактически включённые последним успешным reconcile.
    var activeLeakGroups: [String] = []
    /// Известно ли фактическое состояние групп: после провалившегося reconcile
    /// врать «выключены» нельзя — блок мог остаться включённым.
    var groupsStateKnown = false
}

/// Единая точка сериализации событий детектора (D2 design.md): растяжка,
/// события пути, плановые пробы и РУ-маяк сходятся сюда, состояние меняет
/// только доменная `StateMachine`, побочные эффекты исполняют use cases.
actor MonitoringCoordinator {
    private var machine = StateMachine()
    private var snapshotValue = MonitoringSnapshot()

    /// Настройки читаются в момент использования: скрытые debug-рычаги §14
    /// правятся через `defaults write` из другого процесса, и закэшированная
    /// копия их бы не увидела.
    private let settingsProvider: @Sendable () -> AppSettings
    private var settings: AppSettings { settingsProvider() }

    private let beacon: any BeaconProbing
    private let directIP: any DirectIPProbing
    private let tripwire: any TripwireMonitoring
    private let path: any PathMonitoring
    private let power: any PowerMonitoring
    private let journal: any JournalStore
    private let notifications: any NotificationPresenting
    private let clock: any Clock
    private let applyPolicy: ApplyPolicy
    private let handleHelperFailure: HandleHelperFailure
    private let evaluateProbe: EvaluateProbe

    private var pathGeneration = 0
    /// Номер последней запущенной пробы: вердикт устаревшей пробы применять
    /// нельзя — иначе поздний protected снимет уже подтверждённую утечку.
    private var probeGeneration = 0
    private var backgroundLoops: [Task<Void, Never>] = []
    /// Слои детектора подняты (растяжка, монитор пути, фоновые петли).
    private var isRunning = false
    /// Детектору разрешено действовать. Сбрасывается в stop()/pause(), чтобы
    /// уже запущенные эффекты не трогали группы LS после остановки.
    private var isActive = true
    /// Приложение завершается: группы закрыты, ничто не должно открыть их.
    private var isTerminating = false
    /// Ретрай закрывающего reconcile, провалившегося при паузе: событий
    /// детектора на паузе нет, и без ретрая needsReconcile мёртв.
    private var pausedCloseRetry: Task<Void, Never>?
    private var startedHeartbeatSeconds: Double?
    private var observers: [Int: @Sendable (MonitoringSnapshot) -> Void] = [:]
    private var nextObserverID = 0

    init(settingsProvider: @escaping @Sendable () -> AppSettings,
         beacon: any BeaconProbing,
         directIP: any DirectIPProbing,
         tripwire: any TripwireMonitoring,
         path: any PathMonitoring,
         power: any PowerMonitoring,
         gateway: any RuleGroupGateway,
         wifi: any WifiPowerGateway,
         journal: any JournalStore,
         notifications: any NotificationPresenting,
         clock: any Clock) {
        self.settingsProvider = settingsProvider
        self.beacon = beacon
        self.directIP = directIP
        self.tripwire = tripwire
        self.path = path
        self.power = power
        self.journal = journal
        self.notifications = notifications
        self.clock = clock
        self.evaluateProbe = EvaluateProbe(beacon: beacon)
        self.applyPolicy = ApplyPolicy(gateway: gateway, journal: journal, clock: clock)
        self.handleHelperFailure = HandleHelperFailure(wifi: wifi,
                                                       journal: journal,
                                                       notifications: notifications,
                                                       clock: clock)
    }

    var snapshot: MonitoringSnapshot { snapshotValue }

    func observe(_ handler: @escaping @Sendable (MonitoringSnapshot) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = handler
        handler(snapshotValue)
        return nextObserverID
    }

    func removeObserver(_ id: Int) {
        observers[id] = nil
    }

    // MARK: - Жизненный цикл

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        isActive = true
        await startPowerLayer()
        await startDetectorLayers()
        // В строгом режиме эффекты старта закрывают группы ДО первой пробы.
        await dispatch(.started, trigger: .startup)
        await refreshDirectIP()
    }

    func stop() async {
        isRunning = false
        isActive = false
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        await power.stop()
        await stopDetectorLayers()
    }

    /// Слой питания живёт с координатором, а не с детектором: pause()
    /// останавливает детекторные слои, но закрытие на засыпании обязано
    /// работать и на паузе — pausedCloseRetry во сне заморожен (Решение 5).
    private func startPowerLayer() async {
        await power.start(
            onWillSleep: { [weak self] in await self?.handleSystemWillSleep() },
            onDidWake: { [weak self] in Task { await self?.handleSystemDidWake() } })
    }

    /// Настройки изменились: перезапускаем растяжку, если поменялся heartbeat.
    /// Всё остальное подхватывается на следующей пробе — координатор читает
    /// настройки через провайдер.
    func settingsChanged() async {
        publish()
        guard isRunning, startedHeartbeatSeconds != settings.heartbeatSeconds else { return }
        await tripwire.stop()
        await startTripwire()
    }

    private func startDetectorLayers() async {
        await startTripwire()
        await path.start { [weak self] info in
            Task { await self?.handlePathChange(info) }
        }
        startBackgroundLoops()
    }

    private func stopDetectorLayers() async {
        backgroundLoops.forEach { $0.cancel() }
        backgroundLoops.removeAll()
        await tripwire.stop()
        await path.stop()
        startedHeartbeatSeconds = nil
    }

    private func startTripwire() async {
        let heartbeat = settings.heartbeatSeconds
        startedHeartbeatSeconds = heartbeat
        await tripwire.start(heartbeatSeconds: heartbeat) { [weak self] in
            Task { await self?.handleTripwireBreak() }
        }
    }

    /// Плановая свежая проба (§4.2, слой 3) и периодическое обновление
    /// прямого РУ-IP. Оба цикла живут, пока координатор запущен.
    private func startBackgroundLoops() {
        backgroundLoops.append(Task { [weak self] in
            while let self, await self.isRunning, !Task.isCancelled {
                await self.sleepProbeInterval()
                guard !Task.isCancelled, await self.isRunning else { return }
                await self.runProbe(trigger: .scheduled)
            }
        })
        backgroundLoops.append(Task { [weak self] in
            while let self, await self.isRunning, !Task.isCancelled {
                await self.sleepRuBeaconInterval()
                guard !Task.isCancelled, await self.isRunning else { return }
                await self.refreshDirectIP()
            }
        })
    }

    private func sleepProbeInterval() async {
        await clock.sleep(seconds: settings.probeSeconds)
    }

    private func sleepRuBeaconInterval() async {
        await clock.sleep(seconds: settings.ruBeaconRefreshSeconds)
    }

    // MARK: - События детектора

    func handleTripwireBreak() async {
        guard isActive else { return }
        await journalFact(.tripwire, "растяжка оборвалась")
        await execute(machine.handle(.tripwireBroken, mode: settings.protectionMode))
    }

    func handlePathChange(_ info: NetworkPathInfo) async {
        snapshotValue.path = info
        // §4.4: ответ РУ-маяка живёт до следующей смены сети — иначе прямой IP
        // прошлой сети остался бы в denylist и дал бы ложную утечку.
        snapshotValue.directRuIP = nil
        snapshotValue.directRuIPUpdated = nil
        publish()
        await tripwire.networkPathChanged()

        pathGeneration += 1
        let generation = pathGeneration
        // Вердикт пробы, запущенной до смены сети, описывает прошлую сеть и
        // больше не авторитетен: поздний protected открыл бы группы уже после
        // закрытия (или на непроверенной сети). Свежую пробу запустит debounce.
        probeGeneration += 1

        guard info.isSatisfied else {
            // Сеть пропала: немедленный Offline без debounce и пробы.
            await journalFact(.path, "сеть пропала: \(info.interfaceDescription)")
            await dispatch(.pathDown, trigger: .path)
            return
        }

        // Строгий режим закрывается сразу, не дожидаясь debounce и вердикта.
        await dispatch(.pathShifted, trigger: .path)

        // Debounce шквала событий: проба уходит только от самого свежего.
        await clock.sleep(seconds: settings.pathDebounceSeconds)
        guard generation == pathGeneration else { return }

        await journalFact(.path, "сетевой путь изменился: \(info.interfaceDescription)")
        await execute(machine.handle(.pathChanged, mode: settings.protectionMode))
        await refreshDirectIP()
    }

    /// Система засыпает (§4.2, слой 4). Возврат из метода — сигнал
    /// инфраструктуре подтвердить системе уход в сон, поэтому закрытие
    /// выполняется здесь же, без отложенных задач.
    func handleSystemWillSleep() async {
        guard !isTerminating else { return }
        // Вердикт пробы, ушедшей до засыпания, описывает прошлую сессию:
        // поздний protected не должен открыть группы в момент засыпания.
        probeGeneration += 1
        await journalFact(.power, "машина засыпает")

        let previous = machine.state
        let effects = machine.handle(.systemWillSleep, mode: settings.protectionMode)
        if machine.state != previous {
            await journalTransition(from: previous, to: machine.state, trigger: .power)
        }
        syncSnapshotFromMachine()
        // Реактивный режим: эффектов нет, группы не трогаем.
        guard !effects.isEmpty else { return }

        // Закрытие — напрямую через forceEnable, минуя reconcile(): его гейт
        // isActive проглотил бы закрытие на паузе, а листинг групп — лишний
        // холодный XPC в бюджете перед сном (Решения 4 и 5 design.md).
        let outcome = await applyPolicy.forceEnable(groups: settings.leakGroups,
                                                    settings: settings)
        switch outcome {
        case .applied:
            await journal.append(JournalEvent(time: await clock.now(),
                                              trigger: .power,
                                              kind: .action("группы закрыты: машина засыпает")))
        case .failed(let error):
            // Приложение переживёт сон — в отличие от завершения, здесь
            // провал обязан взвести needsReconcile через helperFailed, чтобы
            // первый вердикт после пробуждения досверил группы (Решение 8).
            await journal.append(JournalEvent(time: await clock.now(),
                                              trigger: .power,
                                              kind: .warning("не удалось закрыть при засыпании: \(error.message) "
                                                  + "— сверка при первом вердикте после пробуждения")))
        case .skippedNoTarget, .skippedObserveOnly:
            break
        }
        await process(outcome, targetCloses: true)
    }

    /// Система проснулась (полное или служебное пробуждение): немедленная
    /// проба, не в надежде на событие пути — в той же сети путь может не
    /// измениться вовсе.
    func handleSystemDidWake() async {
        guard !isTerminating else { return }
        await journalFact(.power, "машина проснулась")
        guard isActive else { return }
        await dispatch(.systemDidWake, trigger: .power)
    }

    /// Действие пользователя «Проверить сейчас». Без работающего детектора
    /// одиночная проба запрещена: её protected-вердикт открыл бы группы,
    /// за которыми дальше никто не следит (инвариант «…и мониторинг активен»).
    func probeNowByUser() async {
        guard isRunning else { return }
        await execute(machine.handle(.userRequestedProbe, mode: settings.protectionMode))
    }

    func pause() async {
        // Порядок принципиален для строгого режима: закрывающий reconcile
        // из эффектов паузы обязан пройти ДО сброса isActive — гейт в
        // reconcile() иначе его проглотит.
        await execute(machine.handle(.userPaused, mode: settings.protectionMode))
        await journalTransition(to: .paused, trigger: .user, action: "мониторинг на паузе")
        syncSnapshotFromMachine()
        // §5: «детектор остановить» — иначе растяжка, пробы и РУ-маяк
        // продолжали бы работать и трогать сеть.
        isRunning = false
        isActive = false
        await stopDetectorLayers()
        // Закрытие могло провалиться (helper недоступен), а событий, которые
        // повторили бы reconcile, на паузе больше не будет — ретраим сами.
        if settings.protectionMode == .strict, !snapshotValue.groupsStateKnown {
            startPausedCloseRetry()
        }
    }

    /// Пока пауза в строгом режиме не закрыта фактически, каждые 20 с
    /// повторяем закрывающий reconcile — до успеха или возобновления.
    private func startPausedCloseRetry() {
        pausedCloseRetry?.cancel()
        pausedCloseRetry = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.clock.sleep(seconds: 20)
                guard !Task.isCancelled else { return }
                if await self.retryPausedClose() { return }
            }
        }
    }

    /// true — закрыто (или ретрай больше не актуален).
    private func retryPausedClose() async -> Bool {
        guard machine.state == .paused, !isTerminating,
              settings.protectionMode == .strict else { return true }
        await process(applyPolicy.run(target: settings.mapping.managedGroups,
                                      settings: settings),
                      targetCloses: true)
        return snapshotValue.groupsStateKnown
    }

    func resume() async {
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        isActive = true
        if !isRunning {
            isRunning = true
            // После stop() слой питания тоже остановлен; после pause() —
            // жив, и повторный start у монитора обязан быть no-op.
            await startPowerLayer()
            await startDetectorLayers()
        }
        // Мониторинг могли включить тумблером, ни разу не запускав детектор:
        // тогда это старт, а не снятие паузы.
        let event: StateMachine.Event = machine.state == .paused ? .userResumed : .started
        let previous = machine.state
        let effects = machine.handle(event, mode: settings.protectionMode)
        await journalTransition(from: previous, to: machine.state, trigger: .user,
                                action: "мониторинг возобновлён")
        syncSnapshotFromMachine()
        await execute(effects)
        await refreshDirectIP()
    }

    /// Маппинг групп изменился — применяем политику немедленно, не дожидаясь
    /// следующего перехода состояний.
    func reconcileNow() async {
        guard isActive else { return }
        await reconcile(machine.state)
    }

    /// Режим защиты переключён (новое значение уже в настройках). Переходная
    /// цель: «реактивный → строгий» закрывает всё, кроме Protected; «строгий →
    /// реактивный» открывает всё, кроме Leak — реактивная политика Offline и
    /// Paused не трогает, и без явного открытия пользователь остался бы заперт.
    func protectionModeChanged() async {
        // Приложение завершается: группы уже закрыты prepareForTermination(),
        // и отставший переходный reconcile не должен открыть их обратно.
        guard !isTerminating else { return }
        let mode = settings.protectionMode
        await journal.append(JournalEvent(time: await clock.now(), kind: .action(
            mode == .strict
                ? "режим защиты: строгий — открыто только при подтверждённом VPN"
                : "режим защиты: реактивный — блок только при подтверждённой утечке")))

        let target = LeakPolicy.targetEnabledGroups(for: machine.state, mode: mode,
                                                    mapping: settings.mapping) ?? []
        await process(applyPolicy.run(target: target, settings: settings),
                      targetCloses: !target.isEmpty)

        // Checking существует только в строгом режиме: возврат в реактивный
        // нормализует его в Offline; свежая проба заново установит состояние.
        // Без работающего детектора пробу не запускаем: её одиночный
        // protected-вердикт открыл бы группы без дальнейшего надзора.
        guard isRunning else { return }
        await dispatch(.modeSwitched, trigger: .user)
    }

    /// Завершение приложения (Cmd-Q, logout, выключение): в строгом режиме
    /// группы закрываются перед смертью — Little Snitch персистит их состояние,
    /// так что следующая загрузка начнётся закрытой.
    func prepareForTermination() async {
        // Никакая отставшая работа (поздний вердикт, переключение режима,
        // ретрай паузы) не должна открыть группы после этой точки.
        isTerminating = true
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        // Слой питания замолкает: подтверждение сна не должно зависеть от
        // умирающего процесса, а его закрытие уже выполняется ниже.
        await power.stop()
        guard settings.protectionMode == .strict else { return }
        isActive = false
        isRunning = false
        // Без листинга: бюджет завершения мал, а включение идемпотентно.
        let outcome = await applyPolicy.forceEnable(groups: settings.leakGroups,
                                                    settings: settings)
        switch outcome {
        case .applied:
            await journal.append(JournalEvent(time: await clock.now(),
                                              kind: .action("группы закрыты: завершение приложения")))
        case .failed(let error):
            await journal.append(JournalEvent(time: await clock.now(),
                                              kind: .warning("не удалось закрыть при завершении: \(error.message) "
                                                  + "— страховка: dead-man's switch helper")))
        case .skippedNoTarget, .skippedObserveOnly:
            break
        }
    }

    // MARK: - Пробы

    func runProbe(trigger: ProbeTrigger) async {
        probeGeneration += 1
        let generation = probeGeneration

        let result = await evaluateProbe.run(
            criteria: settings.criteria(directRuIP: snapshotValue.directRuIP),
            timeout: settings.probeTimeoutSeconds)

        // Пока проба ходила в сеть, могла уйти более свежая — её вердикт
        // авторитетнее, а этот уже описывает прошлое.
        guard generation == probeGeneration else { return }

        let previousState = machine.state
        snapshotValue.lastCheck = await clock.now()
        snapshotValue.lastTrigger = trigger

        let effects = machine.handle(.probed(result, trigger: trigger),
                                     mode: settings.protectionMode)
        syncSnapshotFromMachine()

        if machine.state != previousState {
            await journalTransition(from: previousState,
                                    to: machine.state,
                                    trigger: trigger,
                                    egressIP: result.trace?.ip.text)
            // Диагноз утечки виден только в уведомлении, а его можно и не
            // увидеть; в журнале он нужен, чтобы разбирать причину потом.
            if machine.state == .leak, let diagnosis = machine.lastDiagnosis {
                await journal.append(JournalEvent(
                    time: await clock.now(),
                    trigger: trigger,
                    egressIP: result.trace?.ip.text,
                    kind: .fact("диагноз: \(Self.describe(diagnosis))")))
            }
        }
        await execute(effects)
    }

    /// РУ-маяк (§4.4): обновляет динамическую часть denylist и переоценивает состояние.
    func refreshDirectIP() async {
        guard let candidate = await directIP.fetchDirectIP(timeout: settings.probeTimeoutSeconds) else {
            return
        }
        let decision = DirectIPGuard.evaluate(
            candidate: candidate,
            lastTrace: machine.lastTrace,
            expectedIPs: settings.criteria(directRuIP: nil).expectedIPs)

        switch decision {
        case .rejectMatchesProtectedEgress(let ip):
            await journal.append(JournalEvent(
                time: await clock.now(),
                trigger: .ruBeacon,
                egressIP: ip.text,
                kind: .warning("РУ-маяк прошёл через VPN, сплит не работает?")))
            // Если такой адрес уже успел попасть в denylist — вычищаем,
            // иначе приложение осталось бы в вечной ложной утечке.
            if snapshotValue.directRuIP == ip {
                snapshotValue.directRuIP = nil
                snapshotValue.directRuIPUpdated = nil
                publish()
                await runProbe(trigger: .ruBeacon)
            }

        case .deferUntilFirstVerdict:
            // Вердикта маяка ещё нет: примем адрес после первой пробы.
            return

        case .accept(let ip):
            let changed = snapshotValue.directRuIP != ip
            snapshotValue.directRuIP = ip
            snapshotValue.directRuIPUpdated = await clock.now()
            publish()
            guard changed else { return }
            await journalFact(.ruBeacon, "прямой IP сети: \(ip.text)")
            await runProbe(trigger: .ruBeacon)
        }
    }

    // MARK: - Исполнение эффектов

    /// Отправляет событие в машину, журналируя переход состояния, если он
    /// случился, и публикуя снапшот до исполнения эффектов.
    private func dispatch(_ event: StateMachine.Event, trigger: ProbeTrigger) async {
        let previous = machine.state
        let effects = machine.handle(event, mode: settings.protectionMode)
        if machine.state != previous {
            await journalTransition(from: previous, to: machine.state, trigger: trigger)
        }
        syncSnapshotFromMachine()
        await execute(effects)
    }

    private func execute(_ effects: [StateMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .probeNow(let trigger):
                await runProbe(trigger: trigger)

            case .scheduleLeakConfirmation:
                await clock.sleep(seconds: settings.leakConfirmationSeconds)
                await runProbe(trigger: .confirmation)

            case .reconcile(let state):
                await reconcile(state)

            case .notifyLeak(let diagnosis):
                await notifyLeak(diagnosis)

            case .notifyProtected:
                if settings.notifyTransitions {
                    await notifications.present(AppNotification(
                        category: .transition,
                        title: "Защита восстановлена",
                        body: "Foreign-трафик снова уходит через VPN. Группы Little Snitch выключены."))
                }

            case .notifyHelperFailure(let message):
                if settings.notifyErrors {
                    await notifications.present(AppNotification(
                        category: .error,
                        title: "Little Snitch недоступен",
                        body: message))
                }

            case .escalate:
                _ = await handleHelperFailure.run(state: machine.state, settings: settings)
            }
        }
    }

    private func reconcile(_ state: EgressState) async {
        // После stop()/pause() отложенные эффекты не должны трогать группы.
        guard isActive else { return }

        let settings = settings
        let closes = LeakPolicy.targetEnabledGroups(
            for: state, mode: settings.protectionMode,
            mapping: settings.mapping)?.isEmpty == false
        await process(applyPolicy.run(state: state, settings: settings),
                      targetCloses: closes)
    }

    /// Общая обработка исхода reconcile: снапшот, восстановление helper,
    /// уведомление о несуществующих группах.
    private func process(_ outcome: ApplyPolicy.Outcome, targetCloses: Bool) async {
        let settings = settings
        switch outcome {
        case .applied(_, let missingGroups):
            if machine.helperUnavailable {
                await execute(machine.handle(.helperRecovered, mode: settings.protectionMode))
            }
            snapshotValue.groupsStateKnown = true
            // Группы активны всякий раз, когда цель их включает: в строгом
            // режиме это не только Leak, но и Offline/Checking/Paused.
            snapshotValue.activeLeakGroups = targetCloses
                ? settings.leakGroups.filter { !missingGroups.contains($0) }
                : []
            // ФТ-5: об ошибке переключения группы надо уведомлять, а не только
            // писать в журнал — иначе про опечатку в имени никто не узнает.
            if !missingGroups.isEmpty, settings.notifyErrors {
                await notifications.present(AppNotification(
                    category: .error,
                    title: "Группа не найдена в Little Snitch",
                    body: "Нет групп: \(missingGroups.joined(separator: ", ")). "
                        + "Проверь имена во вкладке «Группы»."))
            }

        case .skippedNoTarget:
            break

        case .skippedObserveOnly:
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = []

        case .failed(let error):
            // Фактическое состояние групп неизвестно: reconcile не дошёл.
            snapshotValue.groupsStateKnown = false
            await execute(machine.handle(.helperFailed(error.message),
                                         mode: settings.protectionMode))
        }
        syncSnapshotFromMachine()
    }

    /// Формулировка диагноза (§4.1): по источнику совпадения понятно, где
    /// именно порвалась цепочка.
    static func describe(_ diagnosis: LeakDiagnosis) -> String {
        switch diagnosis {
        case .forbiddenServer(let ip): "цепочка вышла напрямую с сервера \(ip.text)"
        case .directRuIP: "полный обход VPN: трафик идёт с прямого IP сети"
        case .foreignEgress: "трафик идёт мимо VPN"
        }
    }

    private func notifyLeak(_ diagnosis: LeakDiagnosis) async {
        guard settings.notifyTransitions else { return }
        let groups = settings.leakGroups.isEmpty
            ? "группы не выбраны в настройках"
            : "включены группы: \(settings.leakGroups.joined(separator: ", "))"
        await notifications.present(AppNotification(
            category: .transition,
            title: "Утечка трафика",
            body: "\(Self.describe(diagnosis)). \(groups)."))
    }

    // MARK: - Снимок и журнал

    private func syncSnapshotFromMachine() {
        snapshotValue.state = machine.state
        snapshotValue.trace = machine.lastTrace
        snapshotValue.diagnosis = machine.lastDiagnosis
        snapshotValue.helperUnavailable = machine.helperUnavailable
        publish()
    }

    private func publish() {
        for handler in observers.values { handler(snapshotValue) }
    }

    private func journalFact(_ trigger: ProbeTrigger, _ text: String) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          trigger: trigger,
                                          kind: .fact(text)))
    }

    private func journalTransition(from: EgressState? = nil,
                                   to: EgressState,
                                   trigger: ProbeTrigger,
                                   egressIP: String? = nil,
                                   action: String? = nil) async {
        await journal.append(JournalEvent(
            time: await clock.now(),
            trigger: trigger,
            egressIP: egressIP,
            kind: .transition(from: from ?? snapshotValue.state, to: to),
            action: action))
    }
}
