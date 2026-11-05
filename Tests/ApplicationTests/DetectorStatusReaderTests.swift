import Foundation
import Testing

@Suite("Чтение статуса детекторов")
struct DetectorStatusReaderTests {
    private func make(_ state: EgressState = .offline, enabled: Bool = true,
                      explanation: DetectorStatusExplanation = .none) -> MonitoringSnapshot {
        var snapshot = MonitoringSnapshot()
        snapshot.detectors = [DetectorSnapshot(id: .primary, name: "Одинаковое имя", isEnabled: enabled,
            mode: .strict, proxy: .direct, groups: ["VPN down"], state: state, explanation: explanation,
            lastCheck: Instant(secondsSinceEpoch: 50), tripwireActive: true)]
        snapshot.activeLeakGroups = ["VPN down"]
        return snapshot
    }
    private func read(_ snapshot: MonitoringSnapshot, id: String? = nil) throws -> StatusDocument {
        try DetectorStatusReader.make(snapshot: snapshot, monitoring: .running, observeOnly: true,
                                      capturedAt: Instant(secondsSinceEpoch: 100), detectorID: id)
    }

    @Test("Каждое доменное состояние", arguments: EgressState.allCases)
    func states(_ state: EgressState) throws {
        let result = try read(make(state))
        #expect(result.detectors?.first?.state.rawValue == state.rawValue)
        #expect(result.detectors?.first?.lastCheck == StatusDocument.timestamp(50))
        #expect(result.groups.active == nil)
        #expect(result.observeOnly)
        try result.validate(detectorID: nil)
    }
    @Test("Выключенный детектор не имеет вердикта")
    func disabled() throws {
        let result = try read(make(.protected, enabled: false), id: DetectorID.primary.rawValue)
        #expect(result.detector?.state == .disabled)
        #expect(result.detector?.lastCheck == nil)
        #expect(result.detector?.explanation == nil)
        #expect(result.detector?.tripwireActive == false)
        try result.validate(detectorID: DetectorID.primary.rawValue)
    }
    @Test("ID не зависит от имени и не поддерживает префикс")
    func identity() throws {
        var snapshot = make()
        var second = snapshot.detectors[0]
        second = DetectorSnapshot(id: DetectorID("second"), name: second.name, isEnabled: false,
                                  mode: .reactive, proxy: .direct, groups: [])
        snapshot.detectors.append(second)
        #expect(try read(snapshot, id: "second").detector?.isEnabled == false)
        #expect(try read(snapshot).detectors?.map(\.id) == [DetectorID.primary.rawValue, "second"])
        #expect(throws: StatusFailure.self) { try read(snapshot, id: "sec") }
        #expect(throws: StatusFailure.self) { try read(snapshot, id: second.name) }
        #expect(try read(MonitoringSnapshot()).detectors?.isEmpty == true)
    }
    @Test("Основания не берутся из сырого trace")
    func evidence() throws {
        let ip = IPAddress("198.51.100.40")!
        var snapshot = make(.protected, explanation: .protected(ProtectionEvidence(expectedIP: ip, warp: .plus)))
        snapshot.detectors[0].trace = BeaconTrace(ip: IPAddress("203.0.113.5")!, warp: .off)
        let result = try read(snapshot)
        guard case .protected(let expected, let warp) = result.detectors?.first?.explanation else {
            Issue.record("Нет принятого основания"); return
        }
        #expect(expected == ip.text)
        #expect(warp == .plus)
        snapshot.detectors[0].explanation = .none
        #expect(try read(snapshot).detectors?.first?.explanation == nil)
        snapshot.detectors[0].state = .checking
        snapshot.detectors[0].explanation = .protected(ProtectionEvidence(expectedIP: ip, warp: .on))
        #expect(try read(snapshot).detectors?.first?.explanation == nil)
    }
    @Test("Все основания Offline", arguments: [DetectorStatusExplanation.OfflineCause.noNetwork, .beaconUnavailable, .unknown])
    func offline(_ cause: DetectorStatusExplanation.OfflineCause) throws {
        let document = try read(make(.offline, explanation: .offline(cause)))
        try document.validate(detectorID: nil)
        guard case .offline = document.detectors?.first?.explanation else { Issue.record("Нет причины Offline"); return }
    }

    @Test("Чтение не запускает пробы или reconcile, жизненный цикл виден")
    func coordinatorRead() async throws {
        let settings = TestData.settings()
        let beacon = FakeBeacon()
        let direct = FakeDirectIP()
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        let coordinator = MonitoringCoordinator(settingsProvider: { settings }, beacon: beacon, directIP: direct,
            tripwire: FakeTripwire(), path: FakePathMonitor(), power: FakePowerMonitor(), gateway: gateway,
            wifi: FakeWifi(), journal: FakeJournal(), notifications: FakeNotifications(), clock: ImmediateClock())
        #expect(try await coordinator.readStatus().monitoring == .stopped)
        #expect(await beacon.callCount == 0)
        #expect(await direct.callCount == 0)
        #expect(await gateway.listCallCount == 0)
        #expect(await gateway.operations.isEmpty)
        await coordinator.start()
        #expect(try await coordinator.readStatus().monitoring == .running)
        await coordinator.pause()
        #expect(try await coordinator.readStatus().monitoring == .paused)
        await coordinator.stop()
    }

    @Test("Общий тумблер выключен: stopped при доменной паузе")
    func disabledMonitoringUsesStopped() async throws {
        let holder = SettingsHolder(TestData.settings())
        let beacon = FakeBeacon()
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        let coordinator = MonitoringCoordinator(settingsProvider: { holder.settings }, beacon: beacon,
            directIP: FakeDirectIP(), tripwire: FakeTripwire(), path: FakePathMonitor(), power: FakePowerMonitor(),
            gateway: gateway, wifi: FakeWifi(), journal: FakeJournal(), notifications: FakeNotifications(),
            clock: ImmediateClock())
        await coordinator.start()
        await coordinator.pause()
        #expect(try await coordinator.readStatus().monitoring == .paused)
        var settings = holder.settings
        settings.monitoringEnabled = false
        holder.set(settings)
        // Тот же порядок, что в AppModel.update при выключении тумблера.
        await coordinator.settingsChanged()
        await coordinator.pause()
        let calls = await beacon.callCount
        let operations = await gateway.operations
        let status = try await coordinator.readStatus()
        #expect(status.monitoring == .stopped)
        #expect(status.overall?.state == .paused)
        #expect(status.detectors?.allSatisfy { $0.state == .paused } == true)
        #expect(await beacon.callCount == calls)
        #expect(await gateway.operations == operations)
        settings.monitoringEnabled = true
        holder.set(settings)
        await coordinator.settingsChanged()
        await coordinator.resume()
        #expect(try await coordinator.readStatus().monitoring == .running)
        await coordinator.stop()
    }
}

@Suite("Жизненный цикл сервера статуса")
struct StatusServiceLifecycleTests {
    private final class Server: StatusServing, @unchecked Sendable {
        let lock = NSLock()
        var starts = 0
        var stops = 0
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func start() throws {
            lock.withLock { starts += 1 }
            if fails { throw StatusFailure.unavailable }
        }
        func stop() { lock.withLock { stops += 1 } }
    }
    @Test("Ошибка listener не прерывает запуск и журналируется один раз", arguments: [false, true])
    func start(_ fails: Bool) async {
        let server = Server(fails: fails)
        let journal = FakeJournal()
        let lifecycle = StatusServiceLifecycle(server: server, journal: journal, clock: ImmediateClock())
        await lifecycle.start()
        await lifecycle.start()
        #expect(server.starts == 1)
        #expect(await journal.recent(limit: 10).count == (fails ? 1 : 0))
        await lifecycle.stop()
        await lifecycle.start()
        #expect(server.starts == 1)
        #expect(server.stops == 1)
    }
}
