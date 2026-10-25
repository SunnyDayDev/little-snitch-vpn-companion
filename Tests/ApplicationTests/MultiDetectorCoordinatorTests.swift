import Foundation
import Testing

/// Координатор с несколькими детекторами: общие слои раздаются всем,
/// пробы и растяжки — свои, группы сводит арбитраж (дельты egress-detection,
/// state-machine, rule-group-control, failsafe-escalation).
@Suite("MonitoringCoordinator — несколько детекторов")
struct MultiDetectorCoordinatorTests {
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
        let settings: SettingsHolder
    }

    private let primary = TestData.primaryID
    private let proxy = TestData.proxyID

    private func makeHarness(settings: AppSettings = TestData.twoDetectors(),
                             groups: [String: Bool] = ["VPN down": false, "Telegram": false],
                             clock: any Clock = ImmediateClock(),
                             directIPFallback: IPAddress? = nil) -> Harness {
        let holder = SettingsHolder(settings)
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
                settingsProvider: { holder.settings }, beacon: beacon, directIP: directIP,
                tripwire: tripwire, path: path, power: power, gateway: gateway,
                wifi: wifi, journal: journal, notifications: notifications, clock: clock),
            beacon: beacon, directIP: directIP, tripwire: tripwire, path: path,
            power: power, gateway: gateway, wifi: wifi, journal: journal,
            notifications: notifications, settings: holder)
    }

    /// Оба детектора в защите: основной — warp=on, прокси — свой выход.
    private func bothProtected(_ harness: Harness) async {
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.proxyProtectedBody), for: proxy)
    }

    private func state(_ harness: Harness, _ id: DetectorID) async -> EgressState? {
        await harness.coordinator.snapshot.detector(id)?.state
    }

    private func texts(_ harness: Harness,
                       _ extract: @escaping (JournalEvent.Kind) -> String?) async -> [String] {
        await harness.journal.events.compactMap { extract($0.kind) }
    }

    // MARK: - 3.1 Рантаймы и снапшот

    @Test("Снапшот: детекторы в порядке настроек, сводное — худшее, виновник назван")
    func snapshotListsDetectorsAndWorst() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)

        await harness.coordinator.runProbe(trigger: .scheduled)

        let snapshot = await harness.coordinator.snapshot
        #expect(snapshot.detectors.map(\.id) == [primary, proxy])
        #expect(snapshot.detector(primary)?.state == .protected)
        #expect(snapshot.detector(proxy)?.state == .leak)
        #expect(snapshot.state == .leak)
        #expect(snapshot.overall.culprit == proxy)
        #expect(snapshot.focus?.name == "Через резидентный прокси")
        #expect(snapshot.trace?.ip == TestData.foreignIP)
    }

    @Test("Выключенный детектор в снапшоте есть, но не пробуется и в сводку не входит")
    func disabledDetectorIsListedButSilent() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyEnabled: false))
        await harness.beacon.setFallback(.body(TestData.protectedBody))

        await harness.coordinator.start()

        let snapshot = await harness.coordinator.snapshot
        #expect(snapshot.detector(proxy)?.isEnabled == false)
        #expect(snapshot.state == .protected)
        #expect(await harness.beacon.calls(for: proxy) == 0)
        #expect(await harness.tripwire.isStarted(proxy) == false)
        #expect(await harness.tripwire.isStarted(primary))
        await harness.coordinator.stop()
    }

    @Test("Проба каждого детектора идёт через его прокси")
    func eachProbeUsesItsProxy() async {
        let harness = makeHarness()
        await bothProtected(harness)

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.beacon.calls(for: primary) == 1)
        #expect(await harness.beacon.calls(for: proxy) == 1)
        #expect(await harness.beacon.lastProxy[primary] == .direct)
        #expect(await harness.beacon.lastProxy[proxy]
            == ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080))
    }

    @Test("Растяжка у каждого детектора своя: хост маяка и прокси детектора")
    func tripwirePerDetector() async {
        var settings = TestData.twoDetectors()
        settings.detectors[1].beacon.primaryURL = "https://example.com/cdn-cgi/trace"
        let harness = makeHarness(settings: settings)
        await bothProtected(harness)

        await harness.coordinator.start()

        #expect(await harness.tripwire.started[primary]?.beaconURL
            == "https://www.cloudflare.com/cdn-cgi/trace")
        #expect(await harness.tripwire.started[proxy]?.beaconURL == "https://example.com/cdn-cgi/trace")
        #expect(await harness.tripwire.started[proxy]?.proxy.kind == .socks5)
        await harness.coordinator.stop()
    }

    @Test("Растяжка выключена у детектора — соединения нет, пробы есть")
    func tripwireOptional() async {
        var settings = TestData.twoDetectors()
        settings.detectors[1].tripwireEnabled = false
        let harness = makeHarness(settings: settings)
        await bothProtected(harness)

        await harness.coordinator.start()

        #expect(await harness.tripwire.isStarted(proxy) == false)
        #expect(await harness.beacon.calls(for: proxy) == 1)
        #expect(await harness.coordinator.snapshot.detector(proxy)?.tripwireActive == false)
        await harness.coordinator.stop()
    }

    @Test("Обрыв растяжки пробует только свой детектор")
    func tripwireBreakIsPerDetector() async {
        let harness = makeHarness()
        await bothProtected(harness)

        await harness.coordinator.handleTripwireBreak(proxy)

        #expect(await harness.beacon.calls(for: proxy) == 1)
        #expect(await harness.beacon.calls(for: primary) == 0)
        let facts = await harness.journal.events.filter {
            if case .fact(let text) = $0.kind { return text.contains("растяжка") } else { return false }
        }
        #expect(facts.first?.detector == "Через резидентный прокси")
    }

    @Test("Подтверждение утечки считается на детектор: по одной leak-пробе у двух — не утечка")
    func confirmationIsPerDetector() async {
        let harness = makeHarness()
        await harness.beacon.enqueue(.body(TestData.leakBody), .body(TestData.protectedBody), for: primary)
        await harness.beacon.enqueue(.body(TestData.leakBody), .body(TestData.proxyProtectedBody), for: proxy)

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await state(harness, primary) == .protected)
        #expect(await state(harness, proxy) == .protected)
        #expect(await harness.gateway.groups.values.allSatisfy { !$0 })
    }

    // MARK: - 3.2 Общие слои

    @Test("Смена сети: пробы всех инвалидируются, после одного debounce — по пробе каждому")
    func pathChangeProbesEveryDetector() async {
        let clock = ManualClock()
        let harness = makeHarness(clock: clock)
        await bothProtected(harness)

        async let first: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))
        async let second: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi + туннель"))
        await clock.waitForSleepers(2)
        await clock.advance(by: 1)
        _ = await (first, second)

        #expect(await harness.beacon.calls(for: primary) == 1)
        #expect(await harness.beacon.calls(for: proxy) == 1)
        #expect(await harness.tripwire.pathChangeCount == 2)
    }

    @Test("Смена сети отбрасывает вердикты проб, ушедших до неё, у всех детекторов")
    func pathChangeDropsStaleVerdicts() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict,
                                                                   proxyMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)

        // Проба прокси-детектора подвисла в полёте
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let inFlight = Task { await harness.coordinator.runProbe(proxy, trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil, "проба не встала в полёте")

        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        await harness.beacon.release()
        await inFlight.value

        #expect(await state(harness, primary) == .offline)
        #expect(await state(harness, proxy) == .offline)
        #expect(await harness.gateway.groups == ["VPN down": true, "Telegram": true])
    }

    @Test("Пропажа сети гасит все детекторы; закрываются группы только строгих")
    func pathDownOfflinesEveryone() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)

        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))

        #expect(await state(harness, primary) == .offline)
        #expect(await state(harness, proxy) == .offline)
        #expect(await harness.gateway.groups["VPN down"] == true)
        #expect(await harness.gateway.groups["Telegram"] == false)
    }

    @Test("Засыпание закрывает строгие, реактивные не трогает; пробуждение пробует всех")
    func sleepAndWakeReachEveryone() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.start()
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": false])
        await harness.gateway.resetOperations()

        await harness.power.simulateWillSleep()

        #expect(await harness.gateway.operations == [RuleGroupOperation(name: "VPN down", enable: true)])
        #expect(await state(harness, primary) == .checking)
        #expect(await state(harness, proxy) == .protected)

        let primaryBefore = await harness.beacon.calls(for: primary)
        let proxyBefore = await harness.beacon.calls(for: proxy)
        await harness.coordinator.handleSystemDidWake()
        #expect(await harness.beacon.calls(for: primary) == primaryBefore + 1)
        #expect(await harness.beacon.calls(for: proxy) == proxyBefore + 1)
        #expect(await harness.gateway.groups["VPN down"] == false)
        await harness.coordinator.stop()
    }

    @Test("Прямой IP сети — в запрещённых каждого детектора: утечка прокси-детектора")
    func directIPAppliesToAllDetectors() async {
        let harness = makeHarness(directIPFallback: TestData.providerIP)
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)

        // Прокси сломался: его маяк видит прямой IP сети
        await harness.beacon.setFallback(.body("ip=192.0.2.30\nwarp=off"), for: proxy)
        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == TestData.providerIP)
        #expect(await state(harness, proxy) == .leak)
        #expect(await state(harness, primary) == .protected)
        if case .directRuIP = await harness.coordinator.snapshot.detector(proxy)?.diagnosis {} else {
            Issue.record("ожидался диагноз полного обхода VPN")
        }
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": true])
    }

    @Test("Guard: ответ РУ-маяка, равный защищённому egress любого детектора, отвергается")
    func guardChecksEveryDetector() async {
        let harness = makeHarness(directIPFallback: TestData.proxyExitIP)
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)

        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == nil)
        let warnings = await texts(harness) { if case .warning(let t) = $0 { t } else { nil } }
        #expect(warnings.contains { $0.contains("сплит") })
    }

    @Test("Немаршрутизируемый ответ РУ-маяка отброшен с предупреждением, годный — принят")
    func nonRoutableRuAnswerIsRejected() async {
        let harness = makeHarness()
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)
        // Основной РУ-маяк ответил через локальный прокси, резервный — честно
        await harness.directIP.enqueue(result: DirectIPResult(
            address: TestData.providerIP, rejected: [loopbackFromYandex]))

        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == TestData.providerIP)
        let warnings = await texts(harness) { if case .warning(let t) = $0 { t } else { nil } }
        #expect(warnings.contains("РУ-маяк вернул немаршрутизируемый адрес 127.0.0.1 — ответ отброшен"))
    }

    @Test("Только немаршрутизируемые ответы: прямой IP не обновляется")
    func onlyNonRoutableKeepsDirectIP() async {
        let harness = makeHarness()
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.directIP.enqueue(result: DirectIPResult(
            address: nil, rejected: [loopbackFromYandex,
                                     DirectIPRejection(beaconURL: "https://ip.beget.ru",
                                                       address: IPAddress("198.18.0.7")!)]))

        await harness.coordinator.refreshDirectIP()

        #expect(await harness.coordinator.snapshot.directRuIP == nil)
        let warnings = await texts(harness) { if case .warning(let t) = $0 { t } else { nil } }
        #expect(warnings.filter { $0.contains("немаршрутизируемый") }.count == 2)
        // Пробы по РУ-маяку не было: адреса нет — переоценивать нечего
        #expect(await harness.beacon.callCount == 2)
    }

    private var loopbackFromYandex: DirectIPRejection {
        DirectIPRejection(beaconURL: "https://yandex.ru/internet/api/v0/ip",
                          address: IPAddress("127.0.0.1")!)
    }

    private func rejectionWarnings(_ harness: Harness) async -> [String] {
        await texts(harness) { if case .warning(let t) = $0 { t } else { nil } }
            .filter { $0.contains("немаршрутизируемый") }
    }

    @Test("Повторный тот же немаршрутизируемый ответ журнал не засоряет; новое значение и смена сети — пишутся")
    func repeatedRejectionIsJournaledOnce() async {
        let harness = makeHarness()
        await bothProtected(harness)
        await harness.coordinator.runProbe(trigger: .startup)
        let same = DirectIPResult(address: TestData.providerIP, rejected: [loopbackFromYandex])

        // Старт и два плановых обновления — одно предупреждение
        for _ in 0..<3 {
            await harness.directIP.enqueue(result: same)
            await harness.coordinator.refreshDirectIP()
        }
        #expect(await rejectionWarnings(harness).count == 1)

        // Новое значение от того же маяка — пишется
        await harness.directIP.enqueue(result: DirectIPResult(
            address: TestData.providerIP,
            rejected: [DirectIPRejection(beaconURL: loopbackFromYandex.beaconURL,
                                         address: IPAddress("198.18.0.7")!)]))
        await harness.coordinator.refreshDirectIP()
        #expect(await rejectionWarnings(harness).count == 2)

        // Фактическая смена сети — прежнее значение пишется снова
        await harness.directIP.enqueue(result: same)
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))
        #expect(await rejectionWarnings(harness).count == 3)

        // Плановое обновление в новой сети и повтор события пути с теми же
        // сведениями — не смена сети, предупреждение не повторяется
        await harness.directIP.enqueue(result: same)
        await harness.coordinator.refreshDirectIP()
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))
        #expect(await rejectionWarnings(harness).count == 3)
    }

    @Test("Guard: без вердикта ни одного детектора прямой IP откладывается")
    func guardDefersWithoutVerdicts() async {
        let harness = makeHarness(directIPFallback: TestData.providerIP)
        await harness.coordinator.refreshDirectIP()
        #expect(await harness.coordinator.snapshot.directRuIP == nil)
    }

    // MARK: - 3.3 Reconcile по арбитражу

    @Test("Утечка одного при защите другого закрывает только его группы")
    func leakClosesOnlyItsGroups() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        // warp=on для прокси-детектора — чужой путь: утечка
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: proxy)

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await state(harness, primary) == .protected)
        #expect(await state(harness, proxy) == .leak)
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": true])
        #expect(await harness.coordinator.snapshot.activeLeakGroups == ["Telegram"])
    }

    @Test("Общая группа остаётся закрытой, пока её держит хоть один детектор")
    func sharedGroupHeldByAnyone() async {
        let harness = makeHarness(
            settings: TestData.twoDetectors(primaryGroups: ["VPN down", "Общая"],
                                            proxyGroups: ["Telegram", "Общая"]),
            groups: ["VPN down": false, "Telegram": false, "Общая": false])
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.gateway.groups["Общая"] == true)

        // Основной снова проверен Protected — общая группа всё ещё нужна прокси
        await harness.coordinator.runProbe(primary, trigger: .scheduled)
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": true, "Общая": true])

        // Прокси восстановился — все согласны открыть
        await harness.beacon.setFallback(.body(TestData.proxyProtectedBody), for: proxy)
        await harness.coordinator.runProbe(proxy, trigger: .scheduled)
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": false, "Общая": false])
    }

    @Test("Никто не определяет — группы не трогаются")
    func nobodyDecidesLeavesGroups() async {
        let harness = makeHarness(groups: ["VPN down": true, "Telegram": true])
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)

        #expect(await harness.gateway.operations.isEmpty)
        #expect(await harness.gateway.listCallCount == 0)
        #expect(await harness.gateway.groups == ["VPN down": true, "Telegram": true])
    }

    @Test("Выключенный детектор не участвует: его группы не трогаются чужим Protected")
    func disabledDetectorDoesNotParticipate() async {
        let harness = makeHarness(
            settings: TestData.twoDetectors(proxyGroups: ["Telegram", "VPN down"], proxyEnabled: false),
            groups: ["VPN down": true, "Telegram": true])
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)

        await harness.coordinator.runProbe(trigger: .scheduled)

        // Основной открывает свою группу; «Telegram» — только у выключенного
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": true])
    }

    @Test("Реактивный Offline не выключает уже закрытое: группы остаются в «Группы LS»")
    func untouchedGroupsStayActive() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.activeLeakGroups == ["Telegram"])

        // Прокси-детектор ушёл в Offline (реактивный — группы не трогает),
        // основной перепроверен: «Telegram» по-прежнему включена
        await harness.beacon.setFallback(.offline(.timeout), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)
        await harness.coordinator.reconcileNow()

        #expect(await state(harness, proxy) == .offline)
        #expect(await harness.gateway.groups["Telegram"] == true)
        #expect(await harness.coordinator.snapshot.activeLeakGroups == ["Telegram"])
    }

    // MARK: - 3.4 Старт, пауза, сон, завершение

    @Test("Старт со смешанными режимами: строгий закрыт до пробы, реактивный пробует сразу")
    func startWithMixedModes() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await bothProtected(harness)

        await harness.coordinator.start()

        // Первая операция — закрытие строгого до первой пробы, затем открытие
        // по Protected; «Telegram» реактивного не трогалась ни разу
        #expect(await harness.gateway.operations == [
            RuleGroupOperation(name: "VPN down", enable: true),
            RuleGroupOperation(name: "VPN down", enable: false),
        ])
        #expect(await state(harness, primary) == .protected)
        #expect(await state(harness, proxy) == .protected)
        await harness.coordinator.stop()
    }

    @Test("Пауза: все детекторы Paused, закрываются только группы строгих")
    func pauseClosesOnlyStrict() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.start()

        await harness.coordinator.pause()

        let snapshot = await harness.coordinator.snapshot
        #expect(snapshot.state == .paused)
        #expect(snapshot.detectors.allSatisfy { $0.state == .paused })
        #expect(await harness.gateway.groups == ["VPN down": true, "Telegram": false])
        #expect(await harness.tripwire.isStarted == false)
    }

    @Test("Возобновление: строгий закрыт до вердикта, реактивный пробует")
    func resumeEveryone() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.start()
        await harness.coordinator.pause()

        await harness.coordinator.resume()

        #expect(await state(harness, primary) == .protected)
        #expect(await state(harness, proxy) == .protected)
        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": false])
        #expect(await harness.tripwire.isStarted(primary))
        #expect(await harness.tripwire.isStarted(proxy))
        await harness.coordinator.stop()
    }

    @Test("Сон при двух строгих: закрытие объединением групп без листинга")
    func sleepWithTwoStrict() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict,
                                                                   proxyMode: .strict))
        await bothProtected(harness)
        await harness.coordinator.start()
        await harness.gateway.resetOperations()

        await harness.coordinator.handleSystemWillSleep()

        #expect(await harness.gateway.listCallCount == 0)
        #expect(Set(await harness.gateway.operations) == [
            RuleGroupOperation(name: "Telegram", enable: true),
            RuleGroupOperation(name: "VPN down", enable: true),
        ])
        #expect(await harness.coordinator.snapshot.activeLeakGroups == ["Telegram", "VPN down"])
        await harness.coordinator.stop()
    }

    @Test("Завершение при двух строгих закрывает обе группы; реактивных не трогает")
    func terminationClosesUnion() async {
        var settings = TestData.twoDetectors(primaryMode: .strict, proxyMode: .strict)
        settings.detectors.append(DetectorConfig(id: DetectorID("третий"), name: "Реактивный",
                                                 groups: ["Соцсети"]))
        let harness = makeHarness(settings: settings,
                                  groups: ["VPN down": false, "Telegram": false, "Соцсети": false])
        await harness.beacon.setFallback(.body(TestData.protectedBody))
        await harness.beacon.setFallback(.body(TestData.proxyProtectedBody), for: proxy)
        await harness.coordinator.start()

        await harness.coordinator.prepareForTermination()

        #expect(await harness.gateway.groups == ["VPN down": true, "Telegram": true, "Соцсети": false])
    }

    // MARK: - 3.5 Изменения детектора на лету

    @Test("Строгий → реактивный в Offline: общая группа остаётся, её держит строгий в Checking")
    func modeSwitchKeepsSharedGroup() async {
        let clock = ManualClock()
        let shared = TestData.twoDetectors(primaryGroups: ["Общая"], primaryMode: .strict,
                                           proxyGroups: ["Общая", "Telegram"], proxyMode: .strict)
        let harness = makeHarness(settings: shared, groups: ["Общая": false, "Telegram": false],
                                  clock: clock)
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.gateway.groups["Общая"] == true)

        // Сеть вернулась: оба строгих в Checking до вердикта; основной
        // успевает получить Offline, прокси-детектор ждёт debounce
        async let shift: Void = harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi B"))
        await clock.waitForSleepers(1)
        await harness.coordinator.runProbe(primary, trigger: .user)
        #expect(await state(harness, primary) == .offline)
        #expect(await state(harness, proxy) == .checking)

        var switched = shared
        switched.detectors[0].protectionMode = .reactive
        harness.settings.set(switched)
        await harness.coordinator.settingsChanged()

        // Основной отпустил бы «Общую», но её держит прокси-детектор в Checking
        #expect(await harness.gateway.groups["Общая"] == true)
        let actions = await harness.journal.events.filter {
            if case .action(let text) = $0.kind { return text.contains("режим защиты") } else { return false }
        }
        #expect(actions.first?.detector == "Основной")
        await clock.advance(by: 1)
        _ = await shift
    }

    @Test("Строгий → реактивный с эксклюзивной группой открывает её из Offline")
    func modeSwitchOpensExclusiveGroup() async {
        let harness = makeHarness(settings: TestData.twoDetectors(primaryMode: .strict))
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.gateway.groups["VPN down"] == true)

        harness.settings.set(TestData.twoDetectors())
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": false])
    }

    @Test("Реактивный → строгий без вердикта Protected закрывает группы детектора")
    func modeSwitchToStrictCloses() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.runProbe(trigger: .scheduled)

        harness.settings.set(TestData.twoDetectors(proxyMode: .strict))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": true])
    }

    @Test("Выключение детектора открывает его эксклюзивные группы немедленно")
    func disablingOpensExclusiveGroups() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyMode: .strict))
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.offline(.timeout), for: proxy)
        await harness.coordinator.start()
        #expect(await harness.gateway.groups["Telegram"] == true)

        harness.settings.set(TestData.twoDetectors(proxyMode: .strict, proxyEnabled: false))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups == ["VPN down": false, "Telegram": false])
        #expect(await harness.tripwire.isStarted(proxy) == false)
        #expect(await harness.coordinator.snapshot.detector(proxy)?.isEnabled == false)
        let facts = await harness.journal.events.filter {
            if case .fact(let text) = $0.kind { return text == "детектор выключен" } else { return false }
        }
        #expect(facts.first?.detector == "Через резидентный прокси")
        await harness.coordinator.stop()
    }

    @Test("Выключение не трогает общую группу, которую держит другой детектор")
    func disablingKeepsSharedGroup() async {
        let harness = makeHarness(
            settings: TestData.twoDetectors(primaryGroups: ["Общая"], primaryMode: .strict,
                                            proxyGroups: ["Общая"]),
            groups: ["Общая": true])
        await harness.beacon.setFallback(.offline(.timeout), for: primary)
        await harness.beacon.setFallback(.body(TestData.proxyProtectedBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)

        harness.settings.set(TestData.twoDetectors(primaryGroups: ["Общая"], primaryMode: .strict,
                                                   proxyGroups: ["Общая"], proxyEnabled: false))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups["Общая"] == true)
    }

    @Test("Выключение при утечке: группы открыты, в журнале предупреждение")
    func disablingDuringLeakWarns() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.gateway.groups["Telegram"] == true)

        harness.settings.set(TestData.twoDetectors(proxyEnabled: false))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups["Telegram"] == false)
        let warnings = await harness.journal.events.filter {
            if case .warning(let text) = $0.kind { return text.contains("при утечке") } else { return false }
        }
        #expect(warnings.count == 1)
        #expect(warnings.first?.detector == "Через резидентный прокси")
        #expect(await harness.coordinator.snapshot.state == .protected)
    }

    @Test("Удаление детектора — то же, что выключение, плюс «удалён» в журнале")
    func removingDetector() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyMode: .strict))
        await harness.beacon.setFallback(.offline(.timeout))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.gateway.groups["Telegram"] == true)

        harness.settings.set(TestData.settings())
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups["Telegram"] == false)
        #expect(await harness.coordinator.snapshot.detectors.map(\.id) == [primary])
        let facts = await texts(harness) { if case .fact(let t) = $0 { t } else { nil } }
        #expect(facts.contains("детектор удалён"))
    }

    @Test("Включение строгого детектора при работающем мониторинге: закрыто до пробы, затем проба")
    func enablingStrictDetector() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyMode: .strict, proxyEnabled: false))
        await bothProtected(harness)
        await harness.coordinator.start()
        await harness.gateway.resetOperations()

        harness.settings.set(TestData.twoDetectors(proxyMode: .strict))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.operations == [
            RuleGroupOperation(name: "Telegram", enable: true),
            RuleGroupOperation(name: "Telegram", enable: false),
        ])
        #expect(await state(harness, proxy) == .protected)
        #expect(await harness.tripwire.isStarted(proxy))
        let facts = await texts(harness) { if case .fact(let t) = $0 { t } else { nil } }
        #expect(facts.contains("детектор включён"))
        await harness.coordinator.stop()
    }

    @Test("Новый детектор при работающем мониторинге стартует и в журнале «добавлен»")
    func addingDetector() async {
        let harness = makeHarness(settings: TestData.settings())
        await bothProtected(harness)
        await harness.coordinator.start()

        harness.settings.set(TestData.twoDetectors())
        await harness.coordinator.settingsChanged()

        #expect(await harness.beacon.calls(for: proxy) == 1)
        #expect(await state(harness, proxy) == .protected)
        let facts = await texts(harness) { if case .fact(let t) = $0 { t } else { nil } }
        #expect(facts.contains("детектор добавлен"))
        await harness.coordinator.stop()
    }

    @Test("Детектор, включённый на паузе, встаёт на паузу; строгий закрывается")
    func enablingWhilePaused() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyMode: .strict, proxyEnabled: false))
        await bothProtected(harness)
        await harness.coordinator.start()
        await harness.coordinator.pause()

        harness.settings.set(TestData.twoDetectors(proxyMode: .strict))
        await harness.coordinator.settingsChanged()

        #expect(await state(harness, proxy) == .paused)
        #expect(await harness.gateway.groups["Telegram"] == true)
        #expect(await harness.beacon.calls(for: proxy) == 0)
    }

    @Test("Смена прокси: растяжка детектора переустановлена через новый прокси и проба")
    func proxyChangeRestartsLayers() async {
        let harness = makeHarness()
        await bothProtected(harness)
        await harness.coordinator.start()
        let probesBefore = await harness.beacon.calls(for: proxy)
        let primaryStarts = await harness.tripwire.starts(of: primary)

        var changed = TestData.twoDetectors()
        changed.detectors[1].proxy = ProxyConfig(kind: .httpConnect, host: "203.0.113.6", port: 8080)
        harness.settings.set(changed)
        await harness.coordinator.settingsChanged()

        #expect(await harness.tripwire.started[proxy]?.proxy
            == ProxyConfig(kind: .httpConnect, host: "203.0.113.6", port: 8080))
        #expect(await harness.beacon.calls(for: proxy) == probesBefore + 1)
        #expect(await harness.beacon.lastProxy[proxy]?.kind == .httpConnect)
        // Растяжка другого детектора не тронута
        #expect(await harness.tripwire.starts(of: primary) == primaryStarts)
        await harness.coordinator.stop()
    }

    @Test("Смена heartbeat переустанавливает растяжки всех детекторов")
    func heartbeatChangeRestartsAll() async {
        let harness = makeHarness()
        await bothProtected(harness)
        await harness.coordinator.start()

        var changed = TestData.twoDetectors()
        changed.heartbeatSeconds = 30
        harness.settings.set(changed)
        await harness.coordinator.settingsChanged()

        #expect(await harness.tripwire.started[primary]?.heartbeatSeconds == 30)
        #expect(await harness.tripwire.started[proxy]?.heartbeatSeconds == 30)
        await harness.coordinator.stop()
    }

    @Test("Изменение групп детектора применяется немедленно")
    func groupsChangeReconciles() async {
        let harness = makeHarness(groups: ["VPN down": false, "Telegram": false, "Соцсети": false])
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)

        harness.settings.set(TestData.twoDetectors(proxyGroups: ["Telegram", "Соцсети"]))
        await harness.coordinator.settingsChanged()

        #expect(await harness.gateway.groups["Соцсети"] == true)
    }

    // MARK: - 3.6 Эскалация и наблюдение

    @Test("Эскалация одна на эпизод: второй детектор в Leak Wi-Fi повторно не выключает")
    func escalationOncePerEpisode() async {
        let harness = makeHarness()
        await harness.gateway.failList(with: .helperUnavailable("XPC недоступен"))
        await harness.beacon.setFallback(.body(TestData.leakBody), for: primary)
        await harness.coordinator.runProbe(primary, trigger: .scheduled)
        #expect(await harness.wifi.turnedOffCount == 1)

        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(proxy, trigger: .scheduled)

        #expect(await state(harness, proxy) == .leak)
        #expect(await harness.wifi.turnedOffCount == 1)
        let wifiNotices = await harness.notifications.presented.filter { $0.title == "Wi-Fi выключен" }
        #expect(wifiNotices.count == 1)
        #expect(wifiNotices.first?.body.contains("«Основной»") == true)
        let helperNotices = await harness.notifications.presented.filter {
            $0.title == "Little Snitch недоступен"
        }
        #expect(helperNotices.count == 1)
        #expect(await harness.coordinator.snapshot.helperUnavailable)
    }

    @Test("Восстановление helper открывает новый эпизод эскалации")
    func recoveryResetsEpisode() async {
        let harness = makeHarness()
        await harness.gateway.failList(with: .helperUnavailable("XPC недоступен"))
        await harness.beacon.setFallback(.body(TestData.leakBody), for: primary)
        await harness.coordinator.runProbe(primary, trigger: .scheduled)

        await harness.gateway.failList(with: nil)
        await harness.coordinator.runProbe(primary, trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.helperUnavailable == false)

        await harness.gateway.failList(with: .helperUnavailable("снова"))
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(proxy, trigger: .scheduled)
        #expect(await harness.wifi.turnedOffCount == 2)
    }

    @Test("observeOnly при двух строгих: группы не тронуты, «закрыл бы» с именами")
    func observeOnlyWithTwoStrict() async {
        var settings = TestData.twoDetectors(primaryMode: .strict, proxyMode: .strict)
        settings.observeOnly = true
        let harness = makeHarness(settings: settings)
        await harness.beacon.setFallback(.offline(.timeout))

        await harness.coordinator.runProbe(trigger: .scheduled)
        await harness.coordinator.handleSystemWillSleep()

        #expect(await harness.gateway.operations.isEmpty)
        let wouldClose = await harness.journal.events.filter {
            if case .action(let text) = $0.kind { return text.contains("закрыл бы группы") }
            return false
        }
        #expect(!wouldClose.isEmpty)
        #expect(wouldClose.allSatisfy { $0.detector == "Основной, Через резидентный прокси" })
    }

    // MARK: - 3.7 Имена детекторов в уведомлениях и журнале

    @Test("Уведомление об утечке называет детектор и его группы")
    func leakNotificationNamesDetector() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)

        await harness.coordinator.runProbe(trigger: .scheduled)

        let leaks = await harness.notifications.presented.filter { $0.category == .transition }
        #expect(leaks.map(\.title) == ["Утечка трафика: Через резидентный прокси"])
        #expect(leaks.first?.body == "трафик идёт мимо VPN. включены группы: Telegram.")
    }

    @Test("Восстановление сообщает, что общую группу держит другой детектор")
    func recoveryMentionsHolder() async {
        let harness = makeHarness(
            settings: TestData.twoDetectors(primaryGroups: ["Общая"], primaryMode: .strict,
                                            proxyGroups: ["Общая"]),
            groups: ["Общая": false])
        await harness.beacon.setFallback(.offline(.timeout), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)

        await harness.beacon.setFallback(.body(TestData.proxyProtectedBody), for: proxy)
        await harness.coordinator.runProbe(proxy, trigger: .scheduled)

        let restored = await harness.notifications.presented.filter {
            $0.title == "Защита восстановлена: Через резидентный прокси"
        }
        #expect(restored.count == 1)
        #expect(restored.first?.body.contains("Общая") == true)
        #expect(restored.first?.body.contains("«Основной»") == true)
        #expect(await harness.gateway.groups["Общая"] == true)
    }

    @Test("Группа не найдена: уведомление называет группу и детектор")
    func missingGroupNotificationNamesDetector() async {
        let harness = makeHarness(settings: TestData.twoDetectors(proxyGroups: ["Опечатка"]),
                                  groups: ["VPN down": false])
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)

        await harness.coordinator.runProbe(trigger: .scheduled)

        let errors = await harness.notifications.presented.filter {
            $0.title == "Группа не найдена в Little Snitch"
        }
        #expect(errors.first?.body.contains("«Опечатка» (детектор «Через резидентный прокси»)") == true)
    }

    @Test("Переходы детекторов в журнале несут имя, события пути — без имени")
    func journalCarriesDetectorNames() async {
        let harness = makeHarness()
        await harness.beacon.setFallback(.body(TestData.protectedBody), for: primary)
        await harness.beacon.setFallback(.body(TestData.leakBody), for: proxy)
        await harness.coordinator.runProbe(trigger: .scheduled)
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))

        let events = await harness.journal.events
        let leak = events.first {
            if case .transition(_, .leak) = $0.kind { return true } else { return false }
        }
        #expect(leak?.detector == "Через резидентный прокси")
        #expect(leak?.egressIP == TestData.foreignIP.text)
        let diagnosis = events.first {
            if case .fact(let text) = $0.kind { return text.hasPrefix("диагноз") } else { return false }
        }
        #expect(diagnosis?.detector == "Через резидентный прокси")
        let pathDown = events.first {
            if case .fact(let text) = $0.kind { return text.contains("сеть пропала") } else { return false }
        }
        #expect(pathDown != nil)
        #expect(pathDown?.detector == nil)
    }

    @Test("Без детекторов мониторинг работает вхолостую: сводное — Offline, «детекторов нет»")
    func noDetectorsIdle() async {
        var settings = AppSettings()
        settings.detectors = []
        let harness = makeHarness(settings: settings)

        await harness.coordinator.start()

        let snapshot = await harness.coordinator.snapshot
        #expect(snapshot.state == .offline)
        #expect(!snapshot.overall.hasEnabledDetectors)
        #expect(await harness.beacon.callCount == 0)
        #expect(await harness.gateway.operations.isEmpty)
        await harness.coordinator.stop()
    }
}

/// Failsafe-конфигурация helper — объединение групп включённых строгих
/// детекторов (дельта rule-group-control).
@Suite("AppSettings — failsafe и строгие детекторы")
struct AppSettingsFailsafeTests {
    @Test("Два строгих и реактивный: strictActive, группы строгих")
    func twoStrictDetectors() {
        var settings = TestData.twoDetectors(primaryMode: .strict, proxyMode: .strict)
        settings.detectors.append(DetectorConfig(id: DetectorID("третий"), name: "Реактивный",
                                                 groups: ["Соцсети"]))
        #expect(settings.failsafeConfig == FailsafeConfig(strictActive: true,
                                                          groups: ["Telegram", "VPN down"]))
        #expect(settings.strictDetectors.map(\.id) == [TestData.primaryID, TestData.proxyID])
    }

    @Test("Последний строгий выключен: strictActive снят")
    func lastStrictDisabled() {
        let settings = TestData.twoDetectors(proxyMode: .strict, proxyEnabled: false)
        #expect(settings.failsafeConfig == FailsafeConfig(strictActive: false, groups: []))
        #expect(!settings.strictActive)
    }

    @Test("observeOnly перекрывает строгие: strictActive снят, группы для сведения")
    func observeOnlyDisablesFailsafe() {
        var settings = TestData.twoDetectors(primaryMode: .strict)
        settings.observeOnly = true
        #expect(settings.failsafeConfig.strictActive == false)
        #expect(settings.failsafeConfig.groups == ["VPN down"])
    }

    @Test("Общая группа двух строгих попадает в конфиг один раз")
    func sharedGroupOnce() {
        let settings = TestData.twoDetectors(primaryGroups: ["Общая"], primaryMode: .strict,
                                             proxyGroups: ["Общая"], proxyMode: .strict)
        #expect(settings.failsafeGroups == ["Общая"])
    }

    @Test("Владельцы группы: «также в …» видит и выключенные, арбитраж — только включённые")
    func ownersOfGroup() {
        let settings = TestData.twoDetectors(primaryGroups: ["Общая"], proxyGroups: ["Общая"],
                                             proxyEnabled: false)
        #expect(settings.owners(of: "Общая").map(\.id) == [TestData.primaryID])
        #expect(settings.owners(of: "Общая", excluding: TestData.primaryID, enabledOnly: false)
            .map(\.id) == [TestData.proxyID])
    }
}
