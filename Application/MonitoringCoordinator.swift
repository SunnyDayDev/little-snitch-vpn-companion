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
    private var startedHeartbeatSeconds: Double?
    private var observers: [Int: @Sendable (MonitoringSnapshot) -> Void] = [:]
    private var nextObserverID = 0

    init(settingsProvider: @escaping @Sendable () -> AppSettings,
         beacon: any BeaconProbing,
         directIP: any DirectIPProbing,
         tripwire: any TripwireMonitoring,
         path: any PathMonitoring,
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
        await startDetectorLayers()
        await execute(machine.handle(.started))
        await refreshDirectIP()
    }

    func stop() async {
        isRunning = false
        isActive = false
        await stopDetectorLayers()
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
        await execute(machine.handle(.tripwireBroken))
    }

    func handlePathChange(_ info: NetworkPathInfo) async {
        snapshotValue.path = info
        // §4.4: ответ РУ-маяка живёт до следующей смены сети — иначе прямой IP
        // прошлой сети остался бы в denylist и дал бы ложную утечку.
        snapshotValue.directRuIP = nil
        snapshotValue.directRuIPUpdated = nil
        publish()
        await tripwire.networkPathChanged()

        // Debounce шквала событий: проба уходит только от самого свежего.
        pathGeneration += 1
        let generation = pathGeneration
        await clock.sleep(seconds: settings.pathDebounceSeconds)
        guard generation == pathGeneration else { return }

        await journalFact(.path, "сетевой путь изменился: \(info.interfaceDescription)")
        await execute(machine.handle(.pathChanged))
        await refreshDirectIP()
    }

    /// Действие пользователя «Проверить сейчас».
    func probeNowByUser() async {
        await execute(machine.handle(.userRequestedProbe))
    }

    func pause() async {
        await execute(machine.handle(.userPaused))
        await journalTransition(to: .paused, trigger: .user, action: "мониторинг на паузе")
        syncSnapshotFromMachine()
        // §5: «детектор остановить» — иначе растяжка, пробы и РУ-маяк
        // продолжали бы работать и трогать сеть.
        isRunning = false
        isActive = false
        await stopDetectorLayers()
    }

    func resume() async {
        await journalTransition(to: .offline, trigger: .user, action: "мониторинг возобновлён")
        isActive = true
        if !isRunning {
            isRunning = true
            await startDetectorLayers()
        }
        // Мониторинг могли включить тумблером, ни разу не запускав детектор:
        // тогда это старт, а не снятие паузы.
        await execute(machine.handle(machine.state == .paused ? .userResumed : .started))
        await refreshDirectIP()
    }

    /// Маппинг групп изменился — применяем политику немедленно, не дожидаясь
    /// следующего перехода состояний.
    func reconcileNow() async {
        guard isActive else { return }
        await reconcile(machine.state)
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

        let effects = machine.handle(.probed(result, trigger: trigger))
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
        let outcome = await applyPolicy.run(state: state, settings: settings)
        switch outcome {
        case .applied(_, let missingGroups):
            if machine.helperUnavailable {
                await execute(machine.handle(.helperRecovered))
            }
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = state == .leak
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
            await execute(machine.handle(.helperFailed(error.message)))
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
