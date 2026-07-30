import Testing

@Suite("MonitoringCoordinator")
struct MonitoringCoordinatorTests {
    private struct Harness {
        let coordinator: MonitoringCoordinator
        let beacon: FakeBeacon
        let directIP: FakeDirectIP
        let tripwire: FakeTripwire
        let path: FakePathMonitor
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
        let gateway = FakeRuleGroupGateway(groups: groups)
        let wifi = FakeWifi()
        let journal = FakeJournal()
        let notifications = FakeNotifications()

        return Harness(
            coordinator: MonitoringCoordinator(
                settingsProvider: { settings }, beacon: beacon, directIP: directIP,
                tripwire: tripwire, path: path, gateway: gateway, wifi: wifi,
                journal: journal, notifications: notifications, clock: clock),
            beacon: beacon, directIP: directIP, tripwire: tripwire, path: path,
            gateway: gateway, wifi: wifi, journal: journal, notifications: notifications)
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

        let info = NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi")
        async let first: Void = harness.coordinator.handlePathChange(info)
        async let second: Void = harness.coordinator.handlePathChange(info)
        async let third: Void = harness.coordinator.handlePathChange(info)

        await clock.waitForSleepers(3)
        await clock.advance(by: 1)
        _ = await (first, second, third)

        #expect(await harness.beacon.callCount == 1)
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
        _ = await harness.coordinator.observe { snapshot in
            Task { await box.record(snapshot.state) }
        }
        await harness.coordinator.runProbe(trigger: .startup)
        // Даём хвостовым Task'ам наблюдателя завершиться
        await Task.yield()

        #expect(await box.states.contains(.protected))
    }
}

private actor SnapshotBox {
    private(set) var states: [EgressState] = []
    func record(_ state: EgressState) { states.append(state) }
}
