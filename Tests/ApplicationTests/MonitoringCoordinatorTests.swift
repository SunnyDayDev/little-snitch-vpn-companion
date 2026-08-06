import Foundation
import Testing

@Suite("MonitoringCoordinator")
struct MonitoringCoordinatorTests {
    private struct Harness {
        let coordinator: MonitoringCoordinator
        let beacon: FakeBeacon
        let directIP: FakeDirectIP
        let tripwire: FakeTripwire
        let path: FakePathMonitor
        let power: FakePowerMonitor
        let gateway: FakeRuleGroupGateway
        let wifi: FakeWifi
        let journal: FakeJournal
        let notifications: FakeNotifications
    }

    private func makeHarness(settings: AppSettings = TestData.settings(),
                             groups: [String: Bool] = ["VPN down": false],
                             clock: any Clock = ImmediateClock(),
                             directIPFallback: IPAddress? = nil) -> Harness {
        let beacon = FakeBeacon()
        let directIP = FakeDirectIP(fallback: directIPFallback)
        let tripwire = FakeTripwire()
        let path = FakePathMonitor()
        let power = FakePowerMonitor()
        let gateway = FakeRuleGroupGateway(groups: groups)
        let wifi = FakeWifi()
        let journal = FakeJournal()
        let notifications = FakeNotifications()

        return Harness(
            coordinator: MonitoringCoordinator(
                settingsProvider: { settings }, beacon: beacon, directIP: directIP,
                tripwire: tripwire, path: path, power: power, gateway: gateway,
                wifi: wifi, journal: journal, notifications: notifications,
                clock: clock),
            beacon: beacon, directIP: directIP, tripwire: tripwire, path: path,
            power: power, gateway: gateway, wifi: wifi, journal: journal,
            notifications: notifications)
    }

    // MARK: - Пробы и подтверждение

    @Test("Защищённый egress: состояние Protected, группы выключены")
    func protectedProbe() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.runProbe(trigger: .startup)

        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
    }

    @Test("Одна leak-проба не блокирует: нужна подтверждающая")
    func leakNeedsConfirmation() async {
        let harness = makeHarness()
        await harness.beacon.enqueue(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        // Первая утечка → подтверждение уходит второй пробой, которая говорит «защищено»
        await harness.beacon.enqueue(.body(TestData.leakBody), .body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
    }

    @Test("Две leak-пробы подряд: группы включены, уведомление отправлено")
    func confirmedLeakBlocks() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.leakBody))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.gateway.groups["VPN down"] == true)
        let transitions = await harness.notifications.presented.filter { $0.category == .transition }
        #expect(transitions.count == 1)
        #expect(transitions.first?.title == "Утечка трафика")
    }

    @Test("Восстановление снимает блок автоматически")
    func recoveryUnblocks() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.state == .leak)

        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
        let titles = await harness.notifications.presented.map(\.title)
        #expect(titles.contains("Защита восстановлена"))
    }

    @Test("Маяк недоступен → Offline, группы не тронуты")
    func offlineKeepsGroups() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.gateway.operations.isEmpty)
    }

    @Test("Captive portal (ответ без ip=) считается Offline, не утечкой")
    func captivePortalIsOffline() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body("<html>Войдите в сеть</html>"))

        await harness.coordinator.runProbe(trigger: .path)

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.operations.isEmpty)
    }

    // MARK: - Старт, пауза, возобновление

    @Test("Старт: немедленная проба и reconkile рассинхрона")
    func startProbesAndReconciles() async {
        // Группа осталась включённой с прошлого запуска, а egress защищён
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.start()

        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
        #expect(await harness.tripwire.isStarted)
        #expect(await harness.path.isStarted)
        await harness.coordinator.stop()
    }

    @Test("Пауза: пробы не выполняются, группы остаются как были")
    func pauseStopsEverything() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.pause()

        await harness.coordinator.runProbe(trigger: .scheduled)
        await harness.coordinator.handleTripwireBreak()

        #expect(await harness.coordinator.snapshot.state == .paused)
        #expect(await harness.gateway.operations.isEmpty)
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    /// §5: «детектор остановить». Раньше пауза меняла только состояние, а
    /// растяжка, монитор пути и обе фоновые петли продолжали работать.
    @Test("Пауза действительно останавливает слои детектора")
    func pauseStopsDetectorLayers() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        #expect(await harness.tripwire.isStarted)
        #expect(await harness.path.isStarted)

        await harness.coordinator.pause()

        #expect(await harness.tripwire.isStarted == false)
        #expect(await harness.path.isStarted == false)

        await harness.coordinator.resume()
        #expect(await harness.tripwire.isStarted)
        #expect(await harness.path.isStarted)
        await harness.coordinator.stop()
    }

    /// Решение 5 design: слой питания живёт с координатором, а не с
    /// детектором — пауза не должна его выключать.
    @Test("Слой питания переживает паузу, но останавливается со stop()")
    func powerLayerSurvivesPause() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        #expect(await harness.power.isStarted)

        await harness.coordinator.pause()
        #expect(await harness.power.isStarted)

        await harness.coordinator.resume()
        await harness.coordinator.stop()
        #expect(await harness.power.isStarted == false)
    }

    @Test("Засыпание в реактивном режиме группы не трогает")
    func reactiveSleepKeepsGroups() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.state == .leak)
        await harness.gateway.resetOperations()

        await harness.coordinator.handleSystemWillSleep()

        // Состояние и блок нетронуты: контракт «блок только при утечке»
        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.gateway.operations.isEmpty)
        let facts = await harness.journal.events.compactMap { event -> String? in
            guard event.trigger == .power, case .fact(let text) = event.kind else { return nil }
            return text
        }
        #expect(facts.contains { $0.contains("засыпает") })
    }

    @Test("Пробуждение в реактивном режиме запускает пробу")
    func reactiveWakeProbes() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        let probesBefore = await harness.beacon.callCount

        await harness.coordinator.handleSystemDidWake()

        #expect(await harness.beacon.callCount == probesBefore + 1)
        #expect(await harness.coordinator.snapshot.lastTrigger == .power)
    }

    @Test("Пробуждение через фейк-монитор доходит до пробы")
    func wakeWiringDelivers() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        let probesBefore = await harness.beacon.callCount
        // Подписка ДО пробуждения: в поток попадут только пробы после неё,
        // поэтому стартовая проба ожидание не закроет.
        let probes = await harness.beacon.callEvents()

        await harness.power.simulateDidWake()

        // Обработчик пробуждения запускается фоновой задачей: ждём событие
        // пробы, а не опрашиваем счётчик — сторож внутри валит тест, если
        // проводка порвана.
        #expect(await firstEvent(from: probes) != nil, "проба пробуждения не дошла")
        #expect(await harness.beacon.callCount == probesBefore + 1)
        await harness.coordinator.stop()
    }

    /// Регрессия: отложенные эффекты после stop() трогали группы LS.
    @Test("После stop() reconcile не трогает группы")
    func stopPreventsGroupChanges() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.stop()
        await harness.gateway.resetOperations()

        await harness.coordinator.reconcileNow()

        #expect(await harness.gateway.operations.isEmpty)
    }

    @Test("Возобновление: немедленная проба и применение блока")
    func resumeAppliesPolicy() async {
        let harness = makeHarness()
        await harness.coordinator.pause()
        await harness.beacon.setFallback(.body(TestData.leakBody))

        await harness.coordinator.resume()

        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    // MARK: - Триггеры

    @Test("Обрыв растяжки вызывает немедленную пробу")
    func tripwireBreakProbes() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.handleTripwireBreak()

        #expect(await harness.beacon.callCount == 1)
        #expect(await harness.coordinator.snapshot.state == .protected)
    }

    @Test("Шквал событий пути схлопывается в одну пробу")
    func pathEventsAreDebounced() async {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        // Сведения различаются: шквал не дедуплицируется, его гасит debounce
        async let first: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))
        async let second: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi + туннель"))
        async let third: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))

        await clock.waitForSleepers(3)
        await clock.advance(by: 1)
        _ = await (first, second, third)

        #expect(await harness.beacon.callCount == 1)
    }

    // MARK: - Дедупликация событий пути

    @Test("Повтор события пути без смены сведений игнорируется целиком")
    func duplicatePathEventIsIgnored() async {
        let harness = makeHarness(directIPFallback: TestData.providerIP)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        let info = NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi")
        await harness.coordinator.handlePathChange(info)
        #expect(await harness.coordinator.snapshot.directRuIP == TestData.providerIP)
        let journalBefore = await harness.journal.events.count
        let probesBefore = await harness.beacon.callCount
        let ruBeaconBefore = await harness.directIP.callCount

        await harness.coordinator.handlePathChange(info)

        // Ни записи в журнал, ни пробы, ни сброса и перезапроса прямого РУ-IP
        #expect(await harness.journal.events.count == journalBefore)
        #expect(await harness.beacon.callCount == probesBefore)
        #expect(await harness.directIP.callCount == ruBeaconBefore)
        #expect(await harness.coordinator.snapshot.directRuIP == TestData.providerIP)
    }

    @Test("Возврат сети после пропажи не дедуплицируется")
    func pathReturnAfterDownIsProcessed() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        let up = NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi")

        await harness.coordinator.handlePathChange(up)
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        #expect(await harness.coordinator.snapshot.state == .offline)

        // Те же интерфейсы, но isSatisfied другой — событие обрабатывается
        await harness.coordinator.handlePathChange(up)

        #expect(await harness.coordinator.snapshot.state == .protected)
    }

    @Test("Первое событие пути после пробуждения обрабатывается без смены сведений")
    func wakeResetsPathDeduplication() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        let info = NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi")
        await harness.coordinator.handlePathChange(info)

        await harness.coordinator.handleSystemDidWake()
        await harness.coordinator.handlePathChange(info)

        // За время сна сеть могла смениться на неотличимую — факт смены пути
        // в журнале обязан появиться второй раз
        let pathFacts = await harness.journal.events.compactMap { event -> String? in
            guard case .fact(let text) = event.kind else { return nil }
            return text.contains("сетевой путь изменился") ? text : nil
        }
        #expect(pathFacts.count == 2)
    }

    @Test("После паузы и возобновления идентичное событие пути обрабатывается")
    func resumeResetsPathDeduplication() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        let info = NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi")
        await harness.coordinator.handlePathChange(info)

        await harness.coordinator.pause()
        await harness.coordinator.resume()
        await harness.coordinator.handlePathChange(info)

        let pathFacts = await harness.journal.events.compactMap { event -> String? in
            guard case .fact(let text) = event.kind else { return nil }
            return text.contains("сетевой путь изменился") ? text : nil
        }
        #expect(pathFacts.count == 2)
        await harness.coordinator.stop()
    }

    // MARK: - Отказ helper и эскалация

    @Test("Подтверждённая утечка при недоступном helper → эскалация Wi-Fi")
    func helperFailureEscalates() async {
        let harness = makeHarness()
        await harness.gateway.failList(with: .helperUnavailable("XPC недоступен"))
        await harness.beacon.setFallback(.body(TestData.leakBody))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.coordinator.snapshot.helperUnavailable)
        #expect(await harness.wifi.turnedOffCount == 1)
    }

    @Test("Отказ helper при Protected не выключает Wi-Fi")
    func helperFailureWithoutLeakIsQuiet() async {
        let harness = makeHarness(groups: ["VPN down": true])
        await harness.gateway.failList(with: .cliFailed("нет CLI"))
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.runProbe(trigger: .startup)

        #expect(await harness.wifi.turnedOffCount == 0)
        #expect(await harness.coordinator.snapshot.helperUnavailable)
        let errors = await harness.notifications.presented.filter { $0.category == .error }
        #expect(errors.count == 1)
    }

    @Test("Успешный reconcile снимает флаг «helper недоступен»")
    func recoveryClearsHelperFlag() async {
        let harness = makeHarness()
        await harness.gateway.failList(with: .helperUnavailable("boom"))
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.helperUnavailable)

        await harness.gateway.failList(with: nil)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.helperUnavailable == false)
    }

    // MARK: - РУ-маяк

    @Test("Прямой РУ-IP попадает в denylist и переоценивает состояние")
    func directIPEntersDenylist() async {
        // РУ-маяк вернул адрес провайдера, а foreign-маяк потом отвечает с него
        // же — значит foreign-трафик пошёл напрямую: это утечка.
        let harness = makeHarness(directIPFallback: TestData.foreignIP)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        await harness.coordinator.refreshDirectIP()
        #expect(await harness.coordinator.snapshot.directRuIP == TestData.foreignIP)

        await harness.beacon.setFallback(.body("ip=203.0.113.40\nwarp=on\ncolo=DME"))
        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .leak)
        if case .directRuIP = await harness.coordinator.snapshot.diagnosis {} else {
            Issue.record("ожидался диагноз полного обхода VPN")
        }
    }

    /// Регрессия: до исправления вырожденный ответ РУ-маяка, полученный вне
    /// состояния Protected, отравлял denylist собственным egress — приложение
    /// уходило в вечную ложную утечку, из которой не выбраться без перезапуска.
    @Test("Вырожденный ответ РУ-маяка не отравляет denylist в Offline")
    func guardHoldsOutsideProtected() async {
        let harness = makeHarness(directIPFallback: TestData.cloudflareIP)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        // Сеть пропала: состояние Offline, но последний вердикт маяка — protected
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.state == .offline)

        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == nil)
        #expect(await harness.coordinator.snapshot.state != .leak)
    }

    @Test("Смена сети сбрасывает прямой IP: адрес прошлой сети не годится")
    func pathChangeClearsDirectIP() async {
        let harness = makeHarness(directIPFallback: TestData.providerIP)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.coordinator.refreshDirectIP()
        #expect(await harness.coordinator.snapshot.directRuIP == TestData.providerIP)

        await harness.directIP.enqueue(nil)
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))

        #expect(await harness.coordinator.snapshot.directRuIP == nil)
    }

    @Test("Ответ РУ-маяка, равный protected-egress, в denylist не идёт")
    func guardRejectsProtectedEgress() async {
        let harness = makeHarness(directIPFallback: TestData.cloudflareIP)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        #expect(await harness.coordinator.snapshot.state == .protected)

        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == nil)
        #expect(await harness.coordinator.snapshot.state == .protected)
        let warnings = await harness.journal.events.compactMap { event -> String? in
            if case .warning(let text) = event.kind { return text } else { return nil }
        }
        #expect(warnings.contains { $0.contains("сплит") })
    }

    @Test("Недоступный РУ-маяк состояний не меняет")
    func ruBeaconFailureIsHarmless() async {
        let harness = makeHarness(directIPFallback: nil)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.coordinator.snapshot.directRuIP == nil)
    }

    // MARK: - Журнал и наблюдатели

    @Test("Переходы состояний попадают в журнал")
    func transitionsAreJournaled() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.runProbe(trigger: .scheduled)

        let transitions = await harness.journal.events.filter { $0.kind.category == .transition }
        #expect(transitions.count == 1)
        #expect(transitions.first?.egressIP == TestData.foreignIP.text)
        #expect(transitions.first?.trigger == .confirmation)
    }

    @Test("Наблюдатель получает снимок при изменениях")
    func observerReceivesSnapshots() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        let box = SnapshotBox()
        _ = await harness.coordinator.observe { snapshot in box.record(snapshot.state) }
        await harness.coordinator.runProbe(trigger: .startup)

        #expect(box.states.contains(.protected))
    }
}

/// Запись синхронно под замком, а не хвостовым `Task`: планирование такой
/// задачи тесту не подконтрольно, и её пришлось бы дожидаться опросом.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [EgressState] = []

    var states: [EgressState] { lock.withLock { recorded } }

    func record(_ state: EgressState) {
        lock.withLock { recorded.append(state) }
    }
}

/// Строгий режим: «группы выключены ⇔ последний вердикт Protected и мониторинг
/// работает». Проверяются порядок закрытия, гонки и переключение режима.
@Suite("MonitoringCoordinator — строгий режим")
struct StrictCoordinatorTests {
    private struct Harness {
        let coordinator: MonitoringCoordinator
        let beacon: FakeBeacon
        let path: FakePathMonitor
        let tripwire: FakeTripwire
        let power: FakePowerMonitor
        let gateway: FakeRuleGroupGateway
        let wifi: FakeWifi
        let journal: FakeJournal
        let notifications: FakeNotifications
        let settings: SettingsHolder
    }

    private func makeHarness(settings: AppSettings = TestData.settings(mode: .strict),
                             groups: [String: Bool] = ["VPN down": false],
                             clock: any Clock = ImmediateClock()) -> Harness {
        let holder = SettingsHolder(settings)
        let beacon = FakeBeacon()
        let tripwire = FakeTripwire()
        let path = FakePathMonitor()
        let power = FakePowerMonitor()
        let gateway = FakeRuleGroupGateway(groups: groups)
        let wifi = FakeWifi()
        let journal = FakeJournal()
        let notifications = FakeNotifications()

        return Harness(
            coordinator: MonitoringCoordinator(
                settingsProvider: { holder.settings }, beacon: beacon,
                directIP: FakeDirectIP(), tripwire: tripwire, path: path,
                power: power, gateway: gateway, wifi: wifi, journal: journal,
                notifications: notifications, clock: clock),
            beacon: beacon, path: path, tripwire: tripwire, power: power,
            gateway: gateway, wifi: wifi, journal: journal,
            notifications: notifications, settings: holder)
    }

    // MARK: - Старт и вердикты

    @Test("Старт: закрытие ДО первого вердикта, открытие только после Protected")
    func startClosesBeforeFirstVerdict() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.start()

        // Первая операция — закрытие (reconcile(.checking) до пробы),
        // вторая — открытие по protected-вердикту.
        #expect(await harness.gateway.operations
            == [RuleGroupOperation(name: "VPN down", enable: true),
                RuleGroupOperation(name: "VPN down", enable: false)])
        #expect(await harness.coordinator.snapshot.state == .protected)
        await harness.coordinator.stop()
    }

    @Test("Offline-вердикт закрывает группы")
    func offlineVerdictCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.coordinator.snapshot.activeLeakGroups == ["VPN down"])
    }

    @Test("Старт за captive portal: закрыто сразу и остаётся закрытым")
    func captivePortalCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body("<html>Войдите в сеть</html>"))

        await harness.coordinator.start()

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
        await harness.coordinator.stop()
    }

    // MARK: - События пути

    @Test("Пропажа сети закрывает немедленно, без пробы")
    func pathDownClosesWithoutProbe() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        #expect(await harness.gateway.groups["VPN down"] == false)

        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
        // Проба не запускалась: закрытие не ждёт вердикта
        #expect(await harness.beacon.callCount == 1)
    }

    @Test("Гонка: вердикт пробы, запущенной до пропажи сети, отбрасывается")
    func staleVerdictAfterPathDownIsDropped() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        // Проба уходит и подвисает в полёте
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let inFlight = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil, "проба не встала в полёте")

        // Сеть пропала: закрылись
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Проба возвращается с protected — но её вердикт устарел
        await harness.beacon.release()
        await inFlight.value

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    @Test("Гонка: вердикт пробы, запущенной до смены сети, отбрасывается")
    func staleVerdictAfterPathShiftIsDropped() async {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        // Плановая проба висит в полёте в сети A; она вернёт protected,
        // но решать должна только свежая проба сети B
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let inFlight = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil, "проба не встала в полёте")

        // Переключились на сеть B: остаёмся открытыми (мягкая проверка),
        // свежая проба уйдёт после debounce
        async let change: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))
        await clock.waitForSleepers(1)

        // Старая проба вернулась — вердикт устарел и отброшен: счётчик
        // подтверждения и трейс не должны опираться на прошлую сеть
        await harness.beacon.release()
        await inFlight.value

        // Свежая проба сети B говорит «утечка» — с первого раза только
        // подтверждение, второй вердикт закрывает
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await clock.advance(by: 1)
        // Подтверждающая проба ждёт свои 2.5 с
        await clock.waitForSleepers(1)
        await clock.advance(by: 3)
        _ = await change
        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    @Test("Смена сети из открытого состояния не закрывает превентивно")
    func pathShiftFromProtectedStaysOpen() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.gateway.resetOperations()

        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))

        // Никакого вкл/выкл-чёрна: вердикт снова protected, группы не трогались
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.operations.isEmpty)
    }

    @Test("Провал закрытия при паузе ретраится до успеха")
    func pausedCloseFailureIsRetried() async {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        #expect(await harness.gateway.groups["VPN down"] == false)

        // Закрытие на паузе проваливается: helper недоступен
        await harness.gateway.failSet(with: .cliFailed("сбой CLI"))
        await harness.coordinator.pause()
        #expect(await harness.coordinator.snapshot.state == .paused)
        #expect(await harness.gateway.groups["VPN down"] == false)
        #expect(await harness.coordinator.snapshot.groupsStateKnown == false)

        // Helper ожил — ретрай закрывает без участия пользователя
        await harness.gateway.failSet(with: nil)
        await clock.waitForSleepers(1)
        await clock.advance(by: 20)
        // Ретрай работает фоновой задачей: ждём publish снимка, а не опрос.
        #expect(await waitForSnapshot(harness.coordinator) { $0.groupsStateKnown },
                "ретрай так и не закрыл группы")
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    @Test("Включение строгого режима без мониторинга закрывает и не пробует")
    func switchToStrictWithoutMonitoringClosesWithoutProbe() async {
        // Мониторинг выключен с запуска: start() не вызывался вовсе
        let harness = makeHarness(settings: TestData.settings(mode: .reactive))
        harness.settings.set(TestData.settings(mode: .strict))

        await harness.coordinator.protectionModeChanged()

        // Закрыто; одиночная проба без работающего детектора не запускалась —
        // её protected-вердикт открыл бы группы без дальнейшего надзора
        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.beacon.callCount == 0)
    }

    @Test("«Проверить сейчас» без работающего детектора — no-op")
    func userProbeWithoutDetectorIsNoop() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.gateway.resetOperations()

        await harness.coordinator.probeNowByUser()

        #expect(await harness.beacon.callCount == 0)
        #expect(await harness.gateway.operations.isEmpty)
    }

    @Test("Возврат сети после пропажи: закрыто до свежего Protected-вердикта")
    func networkRecoveryStaysClosedUntilVerdict() async {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        // Сеть пропала: закрылись
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Сеть вернулась: до вердикта — Checking, группы остаются закрыты
        async let change: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))
        await clock.waitForSleepers(1)
        #expect(await harness.coordinator.snapshot.state == .checking)
        #expect(await harness.gateway.groups["VPN down"] == true)

        await clock.advance(by: 1)
        _ = await change

        // Вердикт protected открыл
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
    }

    // MARK: - Пауза, возобновление, завершение

    @Test("Пауза закрывает группы до остановки детектора")
    func pauseCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        #expect(await harness.gateway.groups["VPN down"] == false)

        await harness.coordinator.pause()

        #expect(await harness.coordinator.snapshot.state == .paused)
        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.tripwire.isStarted == false)
    }

    @Test("Возобновление: закрыто до вердикта, открытие только по Protected")
    func resumeStaysClosedUntilVerdict() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.pause()
        #expect(await harness.gateway.groups["VPN down"] == true)

        // После возобновления маяк молчит: остаёмся закрытыми
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.resume()
        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Пришёл protected — открылись
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .user)
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
        await harness.coordinator.stop()
    }

    @Test("Завершение приложения закрывает группы")
    func terminationCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        #expect(await harness.gateway.groups["VPN down"] == false)

        await harness.coordinator.prepareForTermination()

        #expect(await harness.gateway.groups["VPN down"] == true)
        let actions = await harness.journal.events.compactMap { event -> String? in
            if case .action(let text) = event.kind { return text } else { return nil }
        }
        #expect(actions.contains { $0.contains("завершение приложения") })
    }

    @Test("Завершение в реактивном режиме групп не трогает")
    func reactiveTerminationIsQuiet() async {
        let harness = makeHarness(settings: TestData.settings(mode: .reactive))
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.gateway.resetOperations()

        await harness.coordinator.prepareForTermination()

        #expect(await harness.gateway.operations.isEmpty)
    }

    // MARK: - Сон и пробуждение

    @Test("Засыпание закрывает группы до подтверждения сна")
    func sleepCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        #expect(await harness.gateway.groups["VPN down"] == false)

        // Возврат simulateWillSleep == момент, когда боевой монитор отправил
        // бы IOAllowPowerChange: к нему группы обязаны быть закрыты.
        await harness.power.simulateWillSleep()

        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.coordinator.snapshot.state == .checking)
        let facts = await harness.journal.events.compactMap { event -> String? in
            guard event.trigger == .power, case .fact(let text) = event.kind else { return nil }
            return text
        }
        #expect(facts.contains { $0.contains("засыпает") })
        let actions = await harness.journal.events.compactMap { event -> String? in
            if case .action(let text) = event.kind { return text } else { return nil }
        }
        #expect(actions.contains { $0.contains("машина засыпает") })
        await harness.coordinator.stop()
    }

    @Test("Засыпание на паузе закрывает: слой питания переживает паузу")
    func sleepWhilePausedCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.pause()
        #expect(await harness.power.isStarted)
        await harness.gateway.resetOperations()

        await harness.power.simulateWillSleep()

        // Идемпотентная страховка: закрытие выполняется, Paused сохраняется
        #expect(await harness.gateway.operations
            == [RuleGroupOperation(name: "VPN down", enable: true)])
        #expect(await harness.coordinator.snapshot.state == .paused)
    }

    @Test("observeOnly: засыпание не трогает группы, но пишет «закрыл бы»")
    func sleepUnderObserveOnlyIsDryRun() async {
        var settings = TestData.settings(mode: .strict)
        settings.observeOnly = true
        let harness = makeHarness(settings: settings)
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)

        await harness.coordinator.handleSystemWillSleep()

        #expect(await harness.gateway.operations.isEmpty)
        let actions = await harness.journal.events.compactMap { event -> String? in
            if case .action(let text) = event.kind { return text } else { return nil }
        }
        #expect(actions.contains { $0.contains("закрыл бы группы") })
    }

    @Test("Провал закрытия на сон: предупреждение, флаг helper, без эскалации")
    func failedSleepCloseSetsHelperFlag() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.gateway.failSet(with: .cliFailed("сбой CLI"))

        await harness.coordinator.handleSystemWillSleep()

        #expect(await harness.coordinator.snapshot.helperUnavailable)
        #expect(await harness.wifi.turnedOffCount == 0)
        #expect(await harness.coordinator.snapshot.groupsStateKnown == false)
        let warnings = await harness.journal.events.compactMap { event -> String? in
            if case .warning(let text) = event.kind { return text } else { return nil }
        }
        #expect(warnings.contains { $0.contains("не удалось закрыть при засыпании") })

        // После пробуждения первый же вердикт досверяет группы (needsReconcile)
        await harness.gateway.failSet(with: nil)
        await harness.coordinator.handleSystemDidWake()
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
    }

    @Test("Пробуждение: проба без события пути, открытие только по вердикту")
    func wakeProbesWithoutPathEvent() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.handleSystemWillSleep()
        #expect(await harness.gateway.groups["VPN down"] == true)
        let probesBefore = await harness.beacon.callCount

        await harness.coordinator.handleSystemDidWake()

        // Проба ушла по событию питания — никаких handlePathChange не было
        #expect(await harness.beacon.callCount == probesBefore + 1)
        #expect(await harness.coordinator.snapshot.lastTrigger == .power)
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
        await harness.coordinator.stop()
    }

    /// Живая приёмка 2026-08-02: в dark wake событие пути дало пробу с
    /// вердиктом Protected, группы открылись — а уход из dark wake обратно
    /// в сон системой не сообщается, и машина проспала 204 с открытой.
    @Test("Dark wake: вердикт Protected не открывает группы до пробуждения")
    func darkWakeVerdictKeepsClosed() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.handleSystemWillSleep()
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Dark wake: сеть шевелится, проба возвращает protected
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))

        #expect(await harness.coordinator.snapshot.state == .checking)
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Полное пробуждение: проба открывает
        await harness.coordinator.handleSystemDidWake()
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await harness.gateway.groups["VPN down"] == false)
        await harness.coordinator.stop()
    }

    @Test("Гонка: вердикт пробы, запущенной до засыпания, отбрасывается")
    func staleVerdictAfterSleepIsDropped() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.runProbe(trigger: .startup)
        #expect(await harness.gateway.groups["VPN down"] == false)

        // Проба уходит и подвисает в полёте
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let inFlight = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil, "проба не встала в полёте")

        // Засыпание: закрылись
        await harness.coordinator.handleSystemWillSleep()
        #expect(await harness.gateway.groups["VPN down"] == true)

        // Проба возвращается с protected — но описывает прошлую сессию
        await harness.beacon.release()
        await inFlight.value

        #expect(await harness.coordinator.snapshot.state == .checking)
        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    // MARK: - Переключение режима на лету

    @Test("Реактивный → строгий при Offline закрывает немедленно")
    func switchToStrictCloses() async {
        let harness = makeHarness(settings: TestData.settings(mode: .reactive))
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.start()
        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.groups["VPN down"] == false)

        harness.settings.set(TestData.settings(mode: .strict))
        await harness.coordinator.protectionModeChanged()

        #expect(await harness.gateway.groups["VPN down"] == true)
        await harness.coordinator.stop()
    }

    @Test("Строгий → реактивный из паузы открывает: некому было бы снять блок")
    func switchToReactiveFromPauseOpens() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.coordinator.start()
        await harness.coordinator.pause()
        #expect(await harness.gateway.groups["VPN down"] == true)

        harness.settings.set(TestData.settings(mode: .reactive))
        await harness.coordinator.protectionModeChanged()

        #expect(await harness.gateway.groups["VPN down"] == false)
        #expect(await harness.coordinator.snapshot.state == .paused)
    }

    @Test("Строгий → реактивный при Leak оставляет блок")
    func switchToReactiveKeepsLeakBlock() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.leakBody))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.state == .leak)
        #expect(await harness.gateway.groups["VPN down"] == true)

        harness.settings.set(TestData.settings(mode: .reactive))
        await harness.coordinator.protectionModeChanged()

        #expect(await harness.gateway.groups["VPN down"] == true)
    }

    // MARK: - Отказоустойчивость

    @Test("Отказ закрытия при Offline не эскалирует Wi-Fi")
    func failedCloseWhileOfflineDoesNotEscalate() async {
        let harness = makeHarness()
        await harness.gateway.failList(with: .helperUnavailable("XPC недоступен"))
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.coordinator.snapshot.helperUnavailable)
        #expect(await harness.wifi.turnedOffCount == 0)
        #expect(await harness.coordinator.snapshot.groupsStateKnown == false)
    }

    @Test("observeOnly побеждает строгий режим: группы не тронуты")
    func observeOnlyWinsOverStrict() async {
        var settings = TestData.settings(mode: .strict)
        settings.observeOnly = true
        let harness = makeHarness(settings: settings)
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await harness.gateway.operations.isEmpty)
        // ФТ-10: обкатка строгого режима видна в журнале
        let actions = await harness.journal.events.compactMap { event -> String? in
            if case .action(let text) = event.kind { return text } else { return nil }
        }
        #expect(actions.contains { $0.contains("закрыл бы группы") })
    }
}
