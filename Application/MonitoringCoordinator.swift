/// Снимок одного детектора для UI: строка блока «Детекторы» в поповере и
/// строка списка во вкладке «Детекторы».
struct DetectorSnapshot: Hashable, Sendable, Identifiable {
    let id: DetectorID
    var name: String
    var isEnabled: Bool
    var mode: ProtectionMode
    var proxy: ProxyConfig
    var groups: [String]
    var state: EgressState = .offline
    var trace: BeaconTrace?
    var diagnosis: LeakDiagnosis?
    var lastCheck: Instant?
    var lastTrigger: ProbeTrigger?
    /// Растяжка детектора поднята — для инфо-строки «Проверка».
    var tripwireActive = false
}

/// Снимок состояния для UI: всё, что показывают поповер и окна.
struct MonitoringSnapshot: Hashable, Sendable {
    /// Все детекторы в порядке настроек, включая выключенные.
    var detectors: [DetectorSnapshot] = []
    /// Сводное состояние — худшее среди включённых (D11 design.md).
    var overall = AggregateStatus(state: .offline, hasEnabledDetectors: false)
    var helperUnavailable = false
    var directRuIP: IPAddress?
    var directRuIPUpdated: Instant?
    var path: NetworkPathInfo?
    /// Группы, фактически включённые по итогам последних успешных reconcile.
    var activeLeakGroups: [String] = []
    /// Известно ли фактическое состояние групп: после провалившегося reconcile
    /// врать «выключены» нельзя — блок мог остаться включённым.
    var groupsStateKnown = false

    var state: EgressState { overall.state }

    func detector(_ id: DetectorID) -> DetectorSnapshot? {
        detectors.first { $0.id == id }
    }

    var enabledDetectors: [DetectorSnapshot] { detectors.filter(\.isEnabled) }

    /// Детектор, о котором говорят шапка и баннер: виновник сводного
    /// состояния, а без него — первый включённый.
    var focus: DetectorSnapshot? {
        overall.culprit.flatMap(detector) ?? enabledDetectors.first
    }

    var trace: BeaconTrace? { focus?.trace }
    var diagnosis: LeakDiagnosis? { focus?.diagnosis }

    /// Самая свежая проба среди включённых детекторов.
    private var latestChecked: DetectorSnapshot? {
        enabledDetectors.filter { $0.lastCheck != nil }
            .max { $0.lastCheck! < $1.lastCheck! }
    }

    var lastCheck: Instant? { latestChecked?.lastCheck }
    var lastTrigger: ProbeTrigger? { latestChecked?.lastTrigger }
}

/// Единая точка сериализации событий всех детекторов (D1 design.md): общие
/// слои (путь, питание, РУ-маяк, пауза, завершение) и рантаймы детекторов
/// (машина, растяжка, плановые пробы, поколения проб) сходятся сюда.
/// Состояние меняют только доменные `StateMachine`, группы — один reconcile
/// по решению `GroupArbiter`, побочные эффекты исполняют use cases.
actor MonitoringCoordinator {
    private struct DetectorRuntime {
        /// Последняя применённая конфигурация: режим и группы меняются только
        /// через `settingsChanged()`, где выполняются переходные reconcile.
        var config: DetectorConfig
        var machine = StateMachine()
        /// Номер последней запущенной пробы из общего счётчика: вердикт
        /// устаревшей пробы применять нельзя — иначе поздний protected снимет
        /// уже подтверждённую утечку. Счётчик общий, чтобы проба, ушедшая до
        /// выключения детектора, не совпала с номером после включения.
        var probeGeneration = 0
        var lastCheck: Instant?
        var lastTrigger: ProbeTrigger?
        /// Слои детектора подняты (растяжка, плановые пробы).
        var layersStarted = false
        var probeLoop: Task<Void, Never>?
        /// С какими параметрами поднята растяжка: смена маяка, прокси или
        /// heartbeat — повод её переустановить.
        var tripwireSignature: TripwireSignature?

        init(config: DetectorConfig) {
            self.config = config
        }
    }

    private struct TripwireSignature: Hashable {
        let beaconURL: String
        let proxy: ProxyConfig
        let heartbeatSeconds: Double
    }

    private var runtimes: [DetectorID: DetectorRuntime] = [:]
    /// Детекторы последних применённых настроек, включая выключенные: по
    /// ним считается дифф в `settingsChanged()` и порядок снапшота.
    private var appliedDetectors: [DetectorConfig]
    private var appliedObserveOnly: Bool
    private var snapshotValue = MonitoringSnapshot()

    /// Настройки читаются в момент использования: скрытые debug-рычаги §14
    /// правятся через `defaults write` из другого процесса, и закэшированная
    /// копия их бы не увидела.
    private let settingsProvider: @Sendable () -> AppSettings
    private var settings: AppSettings { settingsProvider() }

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
    private var probeSequence = 0
    /// Последний ОБРАБОТАННЫЙ путь — память дедупликации: NWPathMonitor дёргает
    /// обработчик и без фактической смены сети (DNS, viability — замер: медиана
    /// 19 с в неподвижной сети), и повтор не должен порождать ни каскада
    /// журнала, ни сброса РУ-маяка, ни проб. Сбрасывается на границах сна и
    /// старта мониторинга: за ними сеть могла смениться на неотличимую.
    private var lastHandledPath: NetworkPathInfo?
    /// Немаршрутизируемые ответы РУ-маяков, о которых уже предупредили в
    /// этой сети: прокси-клиент с TUN отдаёт один и тот же мусор на каждом
    /// обновлении (старт, путь, раз в 5 минут), и журнал не должен им
    /// засоряться. Новое значение или фактическая смена сети — пишется снова.
    private var journaledRejections: Set<DirectIPRejection> = []
    /// Фоновая петля РУ-маяка — общий слой, живёт, пока мониторинг запущен.
    private var sharedLoops: [Task<Void, Never>] = []
    /// Слои подняты (монитор пути, РУ-маяк, слои детекторов).
    private var isRunning = false
    /// Детекторам разрешено действовать. Сбрасывается в stop()/pause(), чтобы
    /// уже запущенные эффекты не трогали группы LS после остановки.
    private var isActive = true
    /// Мониторинг на паузе: общая для всех детекторов (D8 design.md).
    private var isPaused = false
    /// Приложение завершается: группы закрыты, ничто не должно открыть их.
    private var isTerminating = false
    /// Ретрай закрывающего reconcile, провалившегося при паузе: событий
    /// детекторов на паузе нет, и без ретрая needsReconcile мёртв.
    private var pausedCloseRetry: Task<Void, Never>?

    /// Эпизод недоступности helper один на приложение: об отказе сообщаем и
    /// Wi-Fi выключаем один раз, сколько бы детекторов ни было в Leak.
    private var helperUnavailable = false
    private var helperFailureNotified = false
    private var escalatedThisEpisode = false

    /// Reconcile сериализован: проход считает цель от текущих состояний всех
    /// машин, и устаревший проход, доделанный после свежего, открыл бы
    /// группу, которую свежий только что закрыл. Запросы, пришедшие во
    /// время прохода, сливаются в следующий.
    private var reconcileRequested = 0
    private var reconcileCompleted = 0
    private var reconcileRunner: Task<Void, Never>?
    private var pendingOverrides: [GroupArbiter.Participant] = []
    private var pendingBypassesGate = false

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
        // Рантаймы существуют с рождения координатора, а не со старта
        // мониторинга: переключение режима при выключенном мониторинге тоже
        // обязано закрыть группы, а для этого нужна прежняя конфигурация.
        let initial = settingsProvider()
        var initialRuntimes: [DetectorID: DetectorRuntime] = [:]
        for detector in initial.enabledDetectors where initialRuntimes[detector.id] == nil {
            initialRuntimes[detector.id] = DetectorRuntime(config: detector)
        }
        runtimes = initialRuntimes
        appliedDetectors = initial.detectors
        appliedObserveOnly = initial.observeOnly
    }

    var snapshot: MonitoringSnapshot {
        rebuildSnapshot()
        return snapshotValue
    }

    func observe(_ handler: @escaping @Sendable (MonitoringSnapshot) -> Void) -> Int {
        nextObserverID += 1
        observers[nextObserverID] = handler
        rebuildSnapshot()
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
        isPaused = false
        await startPowerLayer()
        await startSharedLayers()
        for id in orderedIDs { await startDetectorLayers(id) }
        // Строгие детекторы закрывают группы ДО первой пробы, реактивные
        // пробуют сразу.
        await broadcast(orderedIDs.map { ($0, .started) }, trigger: .startup)
        await refreshDirectIP()
    }

    func stop() async {
        isRunning = false
        isActive = false
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        await power.stop()
        await stopSharedLayers()
        for id in orderedIDs { await stopDetectorLayers(id) }
    }

    /// Слой питания живёт с координатором, а не с детекторами: pause()
    /// останавливает остальные слои, но закрытие на засыпании обязано
    /// работать и на паузе — pausedCloseRetry во сне заморожен (Решение 5).
    private func startPowerLayer() async {
        await power.start(
            onWillSleep: { [weak self] in await self?.handleSystemWillSleep() },
            onDidWake: { [weak self] in Task { await self?.handleSystemDidWake() } })
    }

    private func startSharedLayers() async {
        // Свежий монитор пути — чистая память дедупликации: первое событие
        // после старта или возобновления обязано пройти полный каскад.
        lastHandledPath = nil
        await path.start { [weak self] info in
            Task { await self?.handlePathChange(info) }
        }
        sharedLoops.append(Task { [weak self] in
            while let self, await self.isRunning, !Task.isCancelled {
                await self.sleepRuBeaconInterval()
                guard !Task.isCancelled, await self.isRunning else { return }
                await self.refreshDirectIP()
            }
        })
    }

    private func stopSharedLayers() async {
        sharedLoops.forEach { $0.cancel() }
        sharedLoops.removeAll()
        await path.stop()
    }

    /// Растяжка (если включена у детектора) и плановая свежая проба (§4.2,
    /// слои 1 и 3) — свои у каждого детектора.
    private func startDetectorLayers(_ id: DetectorID) async {
        guard runtimes[id] != nil else { return }
        runtimes[id]?.layersStarted = true
        await startTripwire(id)
        runtimes[id]?.probeLoop?.cancel()
        runtimes[id]?.probeLoop = Task { [weak self] in
            while let self, await self.isRunning, !Task.isCancelled {
                await self.sleepProbeInterval()
                guard !Task.isCancelled, await self.isRunning else { return }
                await self.runProbe(id, trigger: .scheduled)
            }
        }
    }

    private func stopDetectorLayers(_ id: DetectorID) async {
        runtimes[id]?.probeLoop?.cancel()
        runtimes[id]?.probeLoop = nil
        runtimes[id]?.layersStarted = false
        runtimes[id]?.tripwireSignature = nil
        await tripwire.stop(id)
    }

    private func desiredTripwire(for config: DetectorConfig) -> TripwireSignature? {
        guard config.tripwireEnabled else { return nil }
        return TripwireSignature(beaconURL: config.beacon.primaryURL,
                                 proxy: config.proxy,
                                 heartbeatSeconds: settings.heartbeatSeconds)
    }

    private func startTripwire(_ id: DetectorID) async {
        guard let config = runtimes[id]?.config else { return }
        guard let signature = desiredTripwire(for: config) else {
            runtimes[id]?.tripwireSignature = nil
            await tripwire.stop(id)
            return
        }
        runtimes[id]?.tripwireSignature = signature
        await tripwire.start(id,
                             beaconURL: signature.beaconURL,
                             proxy: signature.proxy,
                             heartbeatSeconds: signature.heartbeatSeconds) { [weak self] in
            Task { await self?.handleTripwireBreak(id) }
        }
    }

    private func sleepProbeInterval() async {
        await clock.sleep(seconds: settings.probeSeconds)
    }

    private func sleepRuBeaconInterval() async {
        await clock.sleep(seconds: settings.ruBeaconRefreshSeconds)
    }

    // MARK: - Изменения настроек на лету

    /// Настройки изменились (новое значение уже в провайдере). Дифф с
    /// последними применёнными: выключенные и удалённые детекторы уходят из
    /// арбитража с переходным reconcile, у оставшихся переключение режима
    /// даёт переходный reconcile по объединённой цели с новым режимом, смена
    /// маяка, прокси или растяжки — перезапуск слоёв детектора и пробу,
    /// новые и включённые детекторы стартуют как при старте мониторинга.
    func settingsChanged() async {
        let settings = settings
        // Приложение завершается: группы уже закрыты prepareForTermination(),
        // и отставший переходный reconcile не должен открыть их обратно.
        guard !isTerminating else { return }

        // План считается синхронно, до первого await: параллельный вызов
        // увидит уже применённый дифф и не повторит его.
        var overrides: [GroupArbiter.Participant] = []
        var retired: [(config: DetectorConfig, state: EgressState, removed: Bool)] = []
        var started: [DetectorID] = []
        var modeSwitched: [(id: DetectorID, mode: ProtectionMode)] = []
        var pathChanged: [DetectorID] = []
        var groupsChanged = false

        let current = Dictionary(settings.detectors.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        for id in orderedIDs {
            guard let runtime = runtimes[id] else { continue }
            guard let updated = current[id], updated.isEnabled else {
                runtimes[id]?.probeLoop?.cancel()
                runtimes[id] = nil
                retired.append((runtime.config, runtime.machine.state, current[id] == nil))
                // Выключенный детектор больше не определит свои группы:
                // эксклюзивные открываются, общие решает арбитраж (D9).
                overrides.append(.init(groups: runtime.config.mapping.managedGroups, target: []))
                continue
            }
            let previous = runtime.config
            runtimes[id]?.config = updated
            if previous.protectionMode != updated.protectionMode {
                modeSwitched.append((id, updated.protectionMode))
                // Переходная цель: «реактивный → строгий» закрывает всё,
                // кроме Protected; «строгий → реактивный» открывает всё,
                // кроме Leak — реактивная политика Offline и Paused не
                // трогает, и без явного открытия пользователь остался бы
                // заперт. Общие группы решает арбитраж.
                let target = LeakPolicy.targetEnabledGroups(
                    for: runtime.machine.state, mode: updated.protectionMode,
                    mapping: updated.mapping) ?? []
                overrides.append(.init(groups: updated.mapping.managedGroups, target: target))
            }
            if previous.groups != updated.groups { groupsChanged = true }
            if previous.beacon != updated.beacon || previous.proxy != updated.proxy
                || previous.tripwireEnabled != updated.tripwireEnabled {
                pathChanged.append(id)
            }
        }
        for detector in settings.enabledDetectors where runtimes[detector.id] == nil {
            runtimes[detector.id] = DetectorRuntime(config: detector)
            started.append(detector.id)
        }
        let previouslyKnown = Set(appliedDetectors.map(\.id))
        let observeToggled = appliedObserveOnly != settings.observeOnly
        appliedDetectors = settings.detectors
        appliedObserveOnly = settings.observeOnly
        publish()

        // Исполнение плана.
        for entry in retired {
            await tripwire.stop(entry.config.id)
            await journalFact(.user, entry.removed ? "детектор удалён" : "детектор выключен",
                              detector: entry.config.name)
            if entry.state == .leak {
                await journal.append(JournalEvent(
                    time: await clock.now(), trigger: .user, detector: entry.config.name,
                    kind: .warning("детектор выключен при утечке — его группы, которые не "
                        + "держат другие детекторы, открыты: повторного Protected от него не будет")))
            }
        }
        for (id, mode) in modeSwitched {
            await journal.append(JournalEvent(
                time: await clock.now(), trigger: .user, detector: runtimes[id]?.config.name,
                kind: .action(mode == .strict
                    ? "режим защиты: строгий — открыто только при подтверждённом VPN"
                    : "режим защиты: реактивный — блок только при подтверждённой утечке")))
        }

        if !overrides.isEmpty {
            await reconcile(overrides: overrides, bypassingGate: true)
        } else if groupsChanged || observeToggled {
            // Снятие observeOnly при строгом режиме обязано закрыть
            // немедленно, а не ближайшей плановой пробой через минуту.
            await reconcileNow()
        }

        // Без работающего мониторинга проб нет: одиночный protected-вердикт
        // открыл бы группы, за которыми дальше никто не следит.
        guard isRunning else {
            if isPaused {
                // Детектор, включённый на паузе, встаёт на паузу вместе со
                // всеми: строгий закрывает свои группы — мимо гейта isActive.
                await broadcast(started.map { ($0, .userPaused) }, trigger: .user,
                                bypassingGate: true)
            }
            await journalStarted(started, known: previouslyKnown)
            return
        }

        for (id, _) in modeSwitched {
            // Checking существует только в строгом режиме: возврат в
            // реактивный нормализует его в Offline; свежая проба заново
            // установит состояние.
            await dispatch(id, .modeSwitched, trigger: .user)
        }
        // Heartbeat общий: его смена переустанавливает все растяжки; маяк,
        // прокси и тумблер растяжки — растяжку своего детектора.
        for id in orderedIDs where runtimes[id]?.layersStarted == true && !started.contains(id) {
            guard let runtime = runtimes[id] else { continue }
            if runtime.tripwireSignature != desiredTripwire(for: runtime.config) {
                await startTripwire(id)
            }
        }
        for id in pathChanged where runtimes[id] != nil {
            // Вердикт пробы, ушедшей по прежнему пути, его больше не описывает.
            invalidateProbes(of: id)
            await runProbe(id, trigger: .user)
        }
        await journalStarted(started, known: previouslyKnown)
        for id in started { await startDetectorLayers(id) }
        await broadcast(started.map { ($0, .started) }, trigger: .user)
    }

    private func journalStarted(_ ids: [DetectorID], known: Set<DetectorID>) async {
        for id in ids {
            guard let name = runtimes[id]?.config.name else { continue }
            await journalFact(.user, known.contains(id) ? "детектор включён" : "детектор добавлен",
                              detector: name)
        }
    }

    // MARK: - События детекторов и общих слоёв

    func handleTripwireBreak(_ id: DetectorID) async {
        guard isActive, let name = runtimes[id]?.config.name else { return }
        await journalFact(.tripwire, "растяжка оборвалась", detector: name)
        await dispatch(id, .tripwireBroken, trigger: .tripwire)
    }

    func handlePathChange(_ info: NetworkPathInfo) async {
        // Повтор без фактической смены сведений — не смена сети: выход до
        // любых эффектов. Снапшот пути при равенстве уже актуален.
        guard info != lastHandledPath else { return }
        lastHandledPath = info
        journaledRejections.removeAll()
        snapshotValue.path = info
        // §4.4: ответ РУ-маяка живёт до следующей смены сети — иначе прямой IP
        // прошлой сети остался бы в denylist и дал бы ложную утечку.
        snapshotValue.directRuIP = nil
        snapshotValue.directRuIPUpdated = nil
        publish()
        await tripwire.networkPathChanged()

        pathGeneration += 1
        let generation = pathGeneration
        // Вердикты проб, запущенных до смены сети, описывают прошлую сеть и
        // больше не авторитетны — у всех детекторов: поздний protected открыл
        // бы группы уже после закрытия (или на непроверенной сети). Свежие
        // пробы запустит debounce.
        invalidateProbes()

        guard info.isSatisfied else {
            // Сеть пропала: немедленный Offline всех детекторов без debounce и проб.
            await journalFact(.path, "сеть пропала: \(info.interfaceDescription)")
            await broadcast(orderedIDs.map { ($0, .pathDown) }, trigger: .path)
            return
        }

        // Строгие детекторы закрываются сразу, не дожидаясь debounce и вердикта.
        await broadcast(orderedIDs.map { ($0, .pathShifted) }, trigger: .path)

        // Debounce шквала событий: пробы уходят только от самого свежего,
        // по одной на детектор.
        await clock.sleep(seconds: settings.pathDebounceSeconds)
        guard generation == pathGeneration else { return }

        await journalFact(.path, "сетевой путь изменился: \(info.interfaceDescription)")
        await broadcast(orderedIDs.map { ($0, .pathChanged) }, trigger: .path)
        await refreshDirectIP()
    }

    /// Система засыпает (§4.2, слой 4). Возврат из метода — сигнал
    /// инфраструктуре подтвердить системе уход в сон, поэтому закрытие
    /// выполняется здесь же, без отложенных задач.
    func handleSystemWillSleep() async {
        guard !isTerminating else { return }
        // Вердикты проб, ушедших до засыпания, описывают прошлую сессию:
        // поздний protected не должен открыть группы в момент засыпания.
        invalidateProbes()
        await journalFact(.power, "машина засыпает")

        var closes = false
        for id in orderedIDs {
            guard let previous = runtimes[id]?.machine.state,
                  let effects = handle(id, .systemWillSleep) else { continue }
            if let state = runtimes[id]?.machine.state, state != previous {
                await journalTransition(id, from: previous, to: state, trigger: .power)
            }
            // Реактивные: эффектов нет, группы не трогаем.
            if !effects.isEmpty { closes = true }
        }
        publish()
        guard closes else { return }

        // Закрытие — напрямую через forceEnable, минуя reconcile: его гейт
        // isActive проглотил бы закрытие на паузе, а листинг групп — лишний
        // холодный XPC в бюджете перед сном (Решения 4 и 5 design.md).
        let groups = strictGroups
        let outcome = await applyPolicy.forceEnable(groups: groups, settings: settings)
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
        await processForced(outcome, groups: groups)
    }

    /// Система проснулась (полное или служебное пробуждение): немедленная
    /// проба каждого детектора, не в надежде на событие пути — в той же сети
    /// путь может не измениться вовсе.
    func handleSystemDidWake() async {
        guard !isTerminating else { return }
        // За время сна сеть могла смениться на неотличимую по NetworkPathInfo
        // (другой Wi-Fi с тем же шлюзом): досыпной памяти дедупликации верить
        // нельзя — первое событие пути после пробуждения обрабатывается всегда.
        lastHandledPath = nil
        await journalFact(.power, "машина проснулась")
        guard isActive else { return }
        await broadcast(orderedIDs.map { ($0, .systemDidWake) }, trigger: .power)
    }

    /// Действие пользователя «Проверить сейчас» — проба каждого включённого
    /// детектора. Без работающего мониторинга одиночная проба запрещена: её
    /// protected-вердикт открыл бы группы, за которыми дальше никто не следит
    /// (инвариант «…и мониторинг активен»).
    func probeNowByUser() async {
        guard isRunning else { return }
        await broadcast(orderedIDs.map { ($0, .userRequestedProbe) }, trigger: .user)
    }

    func pause() async {
        // Порядок принципиален для строгих детекторов: закрывающий reconcile
        // из эффектов паузы обязан пройти ДО сброса isActive — гейт в
        // reconcile иначе его проглотит.
        isPaused = true
        await broadcast(orderedIDs.map { ($0, .userPaused) }, trigger: .user,
                        action: "мониторинг на паузе")
        // §5: «детектор остановить» — иначе растяжки, пробы и РУ-маяк
        // продолжали бы работать и трогать сеть.
        isRunning = false
        isActive = false
        await stopSharedLayers()
        for id in orderedIDs { await stopDetectorLayers(id) }
        publish()
        // Закрытие могло провалиться (helper недоступен), а событий, которые
        // повторили бы reconcile, на паузе больше не будет — ретраим сами.
        if hasStrictRuntime, !snapshotValue.groupsStateKnown {
            startPausedCloseRetry()
        }
    }

    /// Пока пауза строгих детекторов не закрыта фактически, каждые 20 с
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
        guard isPaused, !isTerminating, hasStrictRuntime else { return true }
        await reconcile(bypassingGate: true)
        return snapshotValue.groupsStateKnown
    }

    func resume() async {
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        isActive = true
        isPaused = false
        if !isRunning {
            isRunning = true
            // После stop() слой питания тоже остановлен; после pause() —
            // жив, и повторный start у монитора обязан быть no-op.
            await startPowerLayer()
            await startSharedLayers()
            for id in orderedIDs { await startDetectorLayers(id) }
        }
        // Мониторинг могли включить тумблером, ни разу не запускав детекторы:
        // тогда это старт, а не снятие паузы.
        let events = orderedIDs.map { id -> (DetectorID, StateMachine.Event) in
            (id, runtimes[id]?.machine.state == .paused ? .userResumed : .started)
        }
        await broadcast(events, trigger: .user, action: "мониторинг возобновлён")
        await refreshDirectIP()
    }

    /// Применить политику немедленно, не дожидаясь следующего перехода
    /// состояний.
    func reconcileNow() async {
        guard isActive else { return }
        await reconcile()
    }

    /// Завершение приложения (Cmd-Q, logout, выключение): группы строгих
    /// детекторов закрываются перед смертью — Little Snitch персистит их
    /// состояние, так что следующая загрузка начнётся закрытой.
    func prepareForTermination() async {
        // Никакая отставшая работа (поздний вердикт, переключение режима,
        // ретрай паузы) не должна открыть группы после этой точки.
        isTerminating = true
        pausedCloseRetry?.cancel()
        pausedCloseRetry = nil
        // Слой питания замолкает: подтверждение сна не должно зависеть от
        // умирающего процесса, а его закрытие уже выполняется ниже.
        await power.stop()
        guard hasStrictRuntime else { return }
        isActive = false
        isRunning = false
        // Без листинга: бюджет завершения мал, а включение идемпотентно.
        let outcome = await applyPolicy.forceEnable(groups: strictGroups, settings: settings)
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

    /// Свежая проба каждого включённого детектора — параллельно: пробы
    /// разных путей друг друга не ждут.
    func runProbe(trigger: ProbeTrigger) async {
        await probe(orderedIDs.map { ($0, trigger) })
    }

    func runProbe(_ id: DetectorID, trigger: ProbeTrigger) async {
        guard runtimes[id] != nil else { return }
        probeSequence += 1
        let generation = probeSequence
        runtimes[id]?.probeGeneration = generation

        let settings = settings
        guard let detector = settings.detector(id) ?? runtimes[id]?.config else { return }
        let result = await evaluateProbe.run(
            detector: detector,
            criteria: settings.criteria(for: detector, directRuIP: snapshotValue.directRuIP),
            timeout: settings.probeTimeoutSeconds)
        let now = await clock.now()

        // Пока проба ходила в сеть, могла уйти более свежая — её вердикт
        // авторитетнее, а этот уже описывает прошлое. Выключенный за это
        // время детектор вердикта не получает вовсе.
        guard let runtime = runtimes[id], runtime.probeGeneration == generation else { return }
        let previousState = runtime.machine.state
        runtimes[id]?.lastCheck = now
        runtimes[id]?.lastTrigger = trigger

        guard let effects = handle(id, .probed(result, trigger: trigger)),
              let state = runtimes[id]?.machine.state else { return }
        publish()

        if state != previousState {
            await journalTransition(id, from: previousState, to: state,
                                    trigger: trigger, egressIP: result.trace?.ip.text)
            // Диагноз утечки виден только в уведомлении, а его можно и не
            // увидеть; в журнале он нужен, чтобы разбирать причину потом.
            if state == .leak, let diagnosis = runtimes[id]?.machine.lastDiagnosis {
                await journal.append(JournalEvent(
                    time: await clock.now(),
                    trigger: trigger,
                    detector: runtimes[id]?.config.name,
                    egressIP: result.trace?.ip.text,
                    kind: .fact("диагноз: \(Self.describe(diagnosis))")))
            }
        }
        await execute(id, effects)
    }

    private func probe(_ requests: [(DetectorID, ProbeTrigger)]) async {
        if requests.count == 1, let request = requests.first {
            await runProbe(request.0, trigger: request.1)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for (id, trigger) in requests {
                group.addTask { await self.runProbe(id, trigger: trigger) }
            }
        }
    }

    private func invalidateProbes(of id: DetectorID? = nil) {
        for key in id.map({ [$0] }) ?? Array(runtimes.keys) {
            probeSequence += 1
            runtimes[key]?.probeGeneration = probeSequence
        }
    }

    /// РУ-маяк (§4.4): обновляет динамическую часть denylist всех детекторов
    /// и переоценивает их состояние.
    func refreshDirectIP() async {
        let answer = await directIP.fetchDirectIP(timeout: settings.probeTimeoutSeconds)
        // Немаршрутизируемый ответ — подмена по пути (прокси-клиент с TUN,
        // fake-IP DNS): в denylist ему не место, но пользователь должен
        // узнать, почему ответ основного маяка не годится. Один раз на
        // значение маяка в этой сети.
        for rejection in answer.rejected where journaledRejections.insert(rejection).inserted {
            let ip = rejection.address
            await journal.append(JournalEvent(
                time: await clock.now(),
                trigger: .ruBeacon,
                egressIP: ip.text,
                kind: .warning("РУ-маяк вернул немаршрутизируемый адрес \(ip.text) — ответ отброшен")))
        }
        guard let candidate = answer.address else { return }
        let verdicts = orderedIDs.compactMap { id -> DirectIPGuard.Verdict? in
            guard let runtime = runtimes[id], let trace = runtime.machine.lastTrace else { return nil }
            return DirectIPGuard.Verdict(
                trace: trace,
                expectedIPs: runtime.config.criteria(directRuIP: nil).expectedIPs,
                warpCountsAsProtection: runtime.config.warpCountsAsProtection)
        }

        switch DirectIPGuard.evaluate(candidate: candidate, verdicts: verdicts) {
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
            // Вердикта ещё нет ни у одного детектора: примем адрес после
            // первой пробы.
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

    /// Событие в машину детектора. `nil` — детектора нет (выключен).
    private func handle(_ id: DetectorID, _ event: StateMachine.Event) -> [StateMachine.Effect]? {
        guard var runtime = runtimes[id] else { return nil }
        let effects = runtime.machine.handle(event, mode: runtime.config.protectionMode)
        runtimes[id] = runtime
        return effects
    }

    /// Событие одному детектору: журнал перехода, снапшот, эффекты.
    private func dispatch(_ id: DetectorID, _ event: StateMachine.Event,
                          trigger: ProbeTrigger) async {
        guard let previous = runtimes[id]?.machine.state,
              let effects = handle(id, event),
              let state = runtimes[id]?.machine.state else { return }
        if state != previous {
            await journalTransition(id, from: previous, to: state, trigger: trigger)
        }
        publish()
        await execute(id, effects)
    }

    /// Событие общего слоя всем детекторам. Эффекты машин сводятся: один
    /// reconcile по объединённой цели (до проб — строгие закрываются раньше,
    /// чем уйдёт проба), затем по пробе на детектор параллельно.
    private func broadcast(_ events: [(DetectorID, StateMachine.Event)],
                           trigger: ProbeTrigger,
                           action: String? = nil,
                           bypassingGate: Bool = false) async {
        var reconcileNeeded = false
        var probes: [(DetectorID, ProbeTrigger)] = []
        var other: [(DetectorID, StateMachine.Effect)] = []
        for (id, event) in events {
            guard let previous = runtimes[id]?.machine.state,
                  let effects = handle(id, event),
                  let state = runtimes[id]?.machine.state else { continue }
            if state != previous || action != nil {
                await journalTransition(id, from: previous, to: state,
                                        trigger: trigger, action: action)
            }
            for effect in effects {
                switch effect {
                case .reconcile: reconcileNeeded = true
                case .probeNow(let probeTrigger): probes.append((id, probeTrigger))
                default: other.append((id, effect))
                }
            }
        }
        publish()
        if reconcileNeeded { await reconcile(bypassingGate: bypassingGate) }
        for (id, effect) in other { await execute(id, [effect]) }
        await probe(probes)
    }

    private func execute(_ id: DetectorID, _ effects: [StateMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .probeNow(let trigger):
                await runProbe(id, trigger: trigger)

            case .scheduleLeakConfirmation:
                await clock.sleep(seconds: settings.leakConfirmationSeconds)
                await runProbe(id, trigger: .confirmation)

            case .reconcile:
                await reconcile()

            case .notifyLeak(let diagnosis):
                await notifyLeak(id, diagnosis)

            case .notifyProtected:
                await notifyProtected(id)

            case .notifyHelperFailure(let message):
                // Каждая машина сообщает об отказе раз за свой эпизод, а
                // эпизод один на приложение — уведомление тоже одно.
                guard !helperFailureNotified else { continue }
                helperFailureNotified = true
                if settings.notifyErrors {
                    await notifications.present(AppNotification(
                        category: .error,
                        title: "Little Snitch недоступен",
                        body: message))
                }

            case .escalate:
                // Эскалация — одна на эпизод недоступности helper, сколько
                // бы детекторов ни подтвердили утечку.
                guard !escalatedThisEpisode,
                      let runtime = runtimes[id] else { continue }
                escalatedThisEpisode = true
                _ = await handleHelperFailure.run(state: runtime.machine.state,
                                                  settings: settings,
                                                  detectorName: runtime.config.name)
            }
        }
    }

    // MARK: - Reconcile

    /// Запросить reconcile по объединённой цели и дождаться прохода, который
    /// её учтёт. `overrides` — переходные желания (переключение режима,
    /// выключение детектора), которые не выражаются парой «состояние +
    /// режим»; они, как и `bypassingGate`, проходят мимо гейта isActive:
    /// переход обязан примениться и при выключенном мониторинге.
    private func reconcile(overrides: [GroupArbiter.Participant] = [],
                           bypassingGate: Bool = false) async {
        pendingOverrides += overrides
        if bypassingGate { pendingBypassesGate = true }
        reconcileRequested += 1
        let ticket = reconcileRequested
        while reconcileCompleted < ticket {
            if let runner = reconcileRunner {
                await runner.value
            } else {
                let runner = Task { await self.drainReconciles() }
                reconcileRunner = runner
                await runner.value
            }
        }
    }

    private func drainReconciles() async {
        while reconcileCompleted < reconcileRequested {
            let ticket = reconcileRequested
            let overrides = pendingOverrides
            let bypass = pendingBypassesGate
            pendingOverrides = []
            pendingBypassesGate = false
            await performReconcile(overrides: overrides, bypassingGate: bypass)
            reconcileCompleted = ticket
        }
        reconcileRunner = nil
    }

    private func performReconcile(overrides: [GroupArbiter.Participant],
                                  bypassingGate: Bool) async {
        guard !isTerminating else { return }
        // После stop()/pause() отложенные эффекты не должны трогать группы.
        guard isActive || bypassingGate || !overrides.isEmpty else { return }

        let participants = orderedIDs.compactMap { id -> GroupArbiter.Participant? in
            guard let runtime = runtimes[id] else { return nil }
            return GroupArbiter.Participant(state: runtime.machine.state,
                                            mode: runtime.config.protectionMode,
                                            mapping: runtime.config.mapping)
        }
        let decision = GroupArbiter.decide(participants + overrides)
        let outcome = await applyPolicy.run(decision: decision, settings: settings)
        await process(outcome, decision: decision)
    }

    /// Общая обработка исхода reconcile: снапшот, эпизод helper, уведомление
    /// о несуществующих группах.
    private func process(_ outcome: ApplyPolicy.Outcome, decision: GroupArbiter.Decision) async {
        let settings = settings
        switch outcome {
        case .applied(_, let missingGroups):
            await recoverHelperIfNeeded()
            // Группы вне решения не трогались и сохраняют прежнее известное
            // состояние: реактивный Offline не выключает уже закрытое.
            let mapped = Set(runtimes.values.flatMap(\.config.groups))
            let active = Set(snapshotValue.groupsStateKnown ? snapshotValue.activeLeakGroups : [])
                .union(decision.enable)
                .subtracting(decision.disable)
                .subtracting(missingGroups)
                .intersection(mapped)
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = active.sorted()
            // ФТ-5: об ошибке переключения группы надо уведомлять, а не только
            // писать в журнал — иначе про опечатку в имени никто не узнает.
            if !missingGroups.isEmpty, settings.notifyErrors {
                let described = missingGroups.map { name in
                    let owners = settings.owners(of: name).map { "«\($0.name)»" }
                    return owners.isEmpty
                        ? "«\(name)»"
                        : "«\(name)» (детектор \(owners.joined(separator: ", ")))"
                }
                await notifications.present(AppNotification(
                    category: .error,
                    title: "Группа не найдена в Little Snitch",
                    body: "Нет групп: \(described.joined(separator: ", ")). "
                        + "Проверь имена в настройках детектора."))
            }

        case .skippedNoTarget:
            break

        case .skippedObserveOnly:
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = []

        case .failed(let error):
            await failHelper(error)
        }
        publish()
    }

    /// Исход быстрого закрытия без листинга (сон): включённые группы
    /// добавляются к уже известным.
    private func processForced(_ outcome: ApplyPolicy.Outcome, groups: [String]) async {
        switch outcome {
        case .applied:
            await recoverHelperIfNeeded()
            let known = snapshotValue.groupsStateKnown ? snapshotValue.activeLeakGroups : []
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = Set(known).union(groups).sorted()
        case .skippedNoTarget:
            break
        case .skippedObserveOnly:
            snapshotValue.groupsStateKnown = true
            snapshotValue.activeLeakGroups = []
        case .failed(let error):
            await failHelper(error)
        }
        publish()
    }

    private func recoverHelperIfNeeded() async {
        guard helperUnavailable else { return }
        helperUnavailable = false
        helperFailureNotified = false
        escalatedThisEpisode = false
        for id in orderedIDs { _ = handle(id, .helperRecovered) }
    }

    /// Фактическое состояние групп неизвестно: reconcile не дошёл. Отказ
    /// касается всех детекторов — каждая машина взводит needsReconcile, иначе
    /// её блок остался бы непроверенным до следующего перехода.
    private func failHelper(_ error: RuleGroupGatewayError) async {
        helperUnavailable = true
        snapshotValue.groupsStateKnown = false
        for id in orderedIDs {
            guard let effects = handle(id, .helperFailed(error.message)) else { continue }
            await execute(id, effects)
        }
    }

    // MARK: - Уведомления

    /// Формулировка диагноза (§4.1): по источнику совпадения понятно, где
    /// именно порвалась цепочка.
    static func describe(_ diagnosis: LeakDiagnosis) -> String {
        switch diagnosis {
        case .forbiddenServer(let ip): "цепочка вышла напрямую с сервера \(ip.text)"
        case .directRuIP: "полный обход VPN: трафик идёт с прямого IP сети"
        case .foreignEgress: "трафик идёт мимо VPN"
        }
    }

    private func notifyLeak(_ id: DetectorID, _ diagnosis: LeakDiagnosis) async {
        let settings = settings
        guard settings.notifyTransitions, let detector = runtimes[id]?.config else { return }
        let enabled = detector.groups.filter(snapshotValue.activeLeakGroups.contains)
        let groups = if detector.groups.isEmpty {
            "группы не выбраны в настройках детектора"
        } else if settings.observeOnly {
            "режим наблюдения: группы не тронуты"
        } else {
            "включены группы: \((enabled.isEmpty ? detector.groups : enabled).joined(separator: ", "))"
        }
        await notifications.present(AppNotification(
            category: .transition,
            title: "Утечка трафика: \(detector.name)",
            body: "\(Self.describe(diagnosis)). \(groups)."))
    }

    private func notifyProtected(_ id: DetectorID) async {
        let settings = settings
        guard settings.notifyTransitions, let detector = runtimes[id]?.config else { return }
        // Общая группа может остаться включённой: её держит другой детектор.
        let held = detector.groups.filter(snapshotValue.activeLeakGroups.contains)
        let holders = held.flatMap { settings.owners(of: $0, excluding: id) }.map(\.name)
        let tail = held.isEmpty
            ? "Группы Little Snitch выключены."
            : "Остаются включены: \(held.joined(separator: ", ")) — их держит "
                + "\(Array(Set(holders)).sorted().map { "«\($0)»" }.joined(separator: ", "))."
        await notifications.present(AppNotification(
            category: .transition,
            title: "Защита восстановлена: \(detector.name)",
            body: "Foreign-трафик снова уходит через VPN. \(tail)"))
    }

    // MARK: - Снимок и журнал

    /// Включённые детекторы в порядке настроек.
    private var orderedIDs: [DetectorID] {
        let known = appliedDetectors.map(\.id).filter { runtimes[$0] != nil }
        let rest = runtimes.keys.filter { !known.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return known + rest
    }

    private var hasStrictRuntime: Bool {
        runtimes.values.contains { $0.config.protectionMode == .strict }
    }

    /// Объединение групп включённых строгих детекторов: закрытие на сне и
    /// завершении (D8 design.md).
    private var strictGroups: [String] {
        Array(Set(runtimes.values
            .filter { $0.config.protectionMode == .strict }
            .flatMap(\.config.groups))).sorted()
    }

    private func rebuildSnapshot() {
        var detectors: [DetectorSnapshot] = appliedDetectors.map { config in
            guard let runtime = runtimes[config.id] else {
                return DetectorSnapshot(id: config.id, name: config.name, isEnabled: false,
                                        mode: config.protectionMode, proxy: config.proxy,
                                        groups: config.groups)
            }
            return Self.snapshot(of: runtime)
        }
        let listed = Set(detectors.map(\.id))
        for id in orderedIDs where !listed.contains(id) {
            if let runtime = runtimes[id] { detectors.append(Self.snapshot(of: runtime)) }
        }
        snapshotValue.detectors = detectors
        snapshotValue.overall = AggregateStatus.summarize(
            detectors.map { AggregateStatus.Member(id: $0.id, isEnabled: $0.isEnabled,
                                                   mode: $0.mode, state: $0.state) },
            isPaused: isPaused)
        snapshotValue.helperUnavailable = helperUnavailable
    }

    private static func snapshot(of runtime: DetectorRuntime) -> DetectorSnapshot {
        DetectorSnapshot(id: runtime.config.id,
                         name: runtime.config.name,
                         isEnabled: true,
                         mode: runtime.config.protectionMode,
                         proxy: runtime.config.proxy,
                         groups: runtime.config.groups,
                         state: runtime.machine.state,
                         trace: runtime.machine.lastTrace,
                         diagnosis: runtime.machine.lastDiagnosis,
                         lastCheck: runtime.lastCheck,
                         lastTrigger: runtime.lastTrigger,
                         tripwireActive: runtime.tripwireSignature != nil)
    }

    private func publish() {
        rebuildSnapshot()
        for handler in observers.values { handler(snapshotValue) }
    }

    private func journalFact(_ trigger: ProbeTrigger, _ text: String,
                             detector: String? = nil) async {
        await journal.append(JournalEvent(time: await clock.now(),
                                          trigger: trigger,
                                          detector: detector,
                                          kind: .fact(text)))
    }

    private func journalTransition(_ id: DetectorID,
                                   from: EgressState,
                                   to: EgressState,
                                   trigger: ProbeTrigger,
                                   egressIP: String? = nil,
                                   action: String? = nil) async {
        await journal.append(JournalEvent(
            time: await clock.now(),
            trigger: trigger,
            detector: runtimes[id]?.config.name,
            egressIP: egressIP,
            kind: .transition(from: from, to: to),
            action: action))
    }
}
