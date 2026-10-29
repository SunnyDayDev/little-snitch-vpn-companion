import Foundation
import Testing

private final class StatusSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MonitoringSnapshot] = []
    func append(_ value: MonitoringSnapshot) { lock.withLock { values.append(value) } }
    var all: [MonitoringSnapshot] { lock.withLock { values } }
}

@Suite("Основания принятого состояния")
struct StatusExplanationTests {
    private let id = DetectorID.primary
    private let ip = IPAddress("198.51.100.40")!
    private let body = "ip=198.51.100.40\nwarp=on\ncolo=AMS"

    private struct Harness {
        let settings: SettingsHolder
        let beacon = FakeBeacon()
        let direct = FakeDirectIP()
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false])
        let coordinator: MonitoringCoordinator

        init(mode: ProtectionMode = .reactive, clock: any Clock = ImmediateClock()) {
            var value = TestData.settings(mode: mode)
            value.detectors[0].expectedIPs = ["198.51.100.40"]
            let holder = SettingsHolder(value)
            settings = holder
            coordinator = MonitoringCoordinator(
                settingsProvider: { holder.settings }, beacon: beacon, directIP: direct,
                tripwire: FakeTripwire(), path: FakePathMonitor(), power: FakePowerMonitor(),
                gateway: gateway, wifi: FakeWifi(), journal: FakeJournal(),
                notifications: FakeNotifications(), clock: clock)
        }
    }

    private func explanation(_ harness: Harness) async -> DetectorStatusExplanation? {
        await harness.coordinator.snapshot.detector(id)?.explanation
    }

    @Test("Первый кандидат не подменяет защиту, подтверждение обновляет весь снапшот")
    func confirmationKeepsAcceptedEvidence() async {
        let clock = ManualClock()
        let harness = Harness(clock: clock)
        let snapshots = StatusSnapshots()
        _ = await harness.coordinator.observe { snapshots.append($0) }
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        let protected = DetectorStatusExplanation.protected(ProtectionEvidence(expectedIP: ip, warp: .on))
        #expect(await explanation(harness) == protected)

        await harness.beacon.setFallback(.body(TestData.leakBody))
        let task = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        await clock.waitForSleepers(1)
        #expect(await harness.coordinator.snapshot.state == .protected)
        #expect(await explanation(harness) == protected)
        // Сырой trace уже обновлён: UI обязан брать отдельное основание.
        #expect(await harness.coordinator.snapshot.trace?.ip == TestData.foreignIP)
        await clock.advance(by: 3)
        await task.value
        #expect(await explanation(harness) == .leak(TestData.foreignIP, .foreignEgress))

        await harness.beacon.setFallback(.body("ip=203.0.113.5\nwarp=off"))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await explanation(harness) == .leak(IPAddress("203.0.113.5")!, .foreignEgress))
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await explanation(harness) == protected)
        #expect(snapshots.all.allSatisfy { snapshot in
            guard let detector = snapshot.detector(id) else { return true }
            switch detector.explanation {
            case .protected: return detector.state == .protected
            case .leak: return detector.state == .leak
            default: return true
            }
        })
    }

    @Test("Причина Offline не зависит от режима и меняется при возврате сети",
          arguments: [ProtectionMode.reactive, .strict])
    func offlineCauses(mode: ProtectionMode) async {
        let harness = Harness(mode: mode)
        #expect(await explanation(harness) == .offline(.unknown))
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        #expect(await explanation(harness) == .offline(.noNetwork))
        await harness.coordinator.handlePathChange(
            NetworkPathInfo(isSatisfied: true, interfaceDescription: "Wi-Fi"))
        #expect(await explanation(harness) == .offline(.beaconUnavailable))
    }

    @Test("Во сне protected-проба строгого детектора не становится основанием защиты")
    func asleepRemainsChecking() async {
        let harness = Harness(mode: .strict)
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.coordinator.handleSystemWillSleep()
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await harness.coordinator.snapshot.state == .checking)
        #expect(await explanation(harness) == DetectorStatusExplanation.none)
    }

    @Test("Изменение существенных настроек липко сбрасывает основание", arguments: 0..<6)
    func configurationInvalidates(change: Int) async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        let original = harness.settings.settings
        var updated = original
        switch change {
        case 0: updated.detectors[0].expectedIPs = []
        case 1: updated.detectors[0].forbiddenEgressIPs.append("203.0.113.8")
        case 2: updated.detectors[0].warpCountsAsProtection = false
        case 3: updated.debugIgnoreWarp = true
        case 4: updated.detectors[0].beacon.primaryURL = "https://example.com/trace"
        default: updated.detectors[0].proxy = ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080)
        }
        harness.settings.set(updated)
        if change != 3 { await harness.coordinator.settingsChanged() }
        #expect(await explanation(harness) == DetectorStatusExplanation.none)
        harness.settings.set(original)
        #expect(await explanation(harness) == DetectorStatusExplanation.none)
        #expect(await harness.beacon.callCount == 1)
        await harness.coordinator.runProbe(trigger: .scheduled)
        #expect(await explanation(harness) == .protected(ProtectionEvidence(expectedIP: ip, warp: .on)))
    }

    @Test("Настройки меняются в полёте: старый ответ не получает нового основания")
    func settingsDuringProbe() async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let task = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil)
        var updated = harness.settings.settings
        updated.detectors[0].expectedIPs = []
        harness.settings.set(updated)
        await harness.coordinator.settingsChanged()
        await harness.beacon.release()
        await task.value
        #expect(await explanation(harness) == DetectorStatusExplanation.none)
    }

    @Test("Более свежая проба и смена пути отбрасывают старое основание", arguments: [false, true])
    func staleResponse(pathChanges: Bool) async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let old = Task { await harness.coordinator.runProbe(trigger: .scheduled) }
        #expect(await firstEvent(from: holds) != nil)
        if pathChanges {
            await harness.coordinator.handlePathChange(
                NetworkPathInfo(isSatisfied: false, interfaceDescription: "нет сети"))
        } else {
            await harness.beacon.setFallback(.offline(.timeout))
            await harness.coordinator.runProbe(trigger: .scheduled)
            await harness.beacon.setFallback(.body(body))
        }
        await harness.beacon.release()
        await old.value
        #expect(await harness.coordinator.snapshot.state == .offline)
        #expect(await explanation(harness) == .offline(pathChanges ? .noNetwork : .beaconUnavailable))
    }

    @Test("Имя и группы не сбрасывают основание и не добавляют пробы")
    func presentationOnlySettings() async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        let before = await explanation(harness)
        var updated = harness.settings.settings
        updated.detectors[0].name = "Другой детектор"
        updated.detectors[0].groups = []
        harness.settings.set(updated)
        await harness.coordinator.settingsChanged()
        #expect(await explanation(harness) == before)
        #expect(await harness.beacon.callCount == 1)
    }

    @Test("Пауза, остановка и повторное включение скрывают прежние признаки", arguments: 0..<3)
    func lifecycleClearsEvidence(action: Int) async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        if action == 0 {
            await harness.coordinator.pause()
        } else if action == 1 {
            await harness.coordinator.stop()
        } else {
            var updated = harness.settings.settings
            updated.detectors[0].isEnabled = false
            harness.settings.set(updated)
            await harness.coordinator.settingsChanged()
            updated.detectors[0].isEnabled = true
            harness.settings.set(updated)
            await harness.coordinator.settingsChanged()
        }
        let result = await explanation(harness)
        #expect(result == DetectorStatusExplanation.none || result == .offline(.unknown))
    }

    @Test("Новый прямой IP скрывает основание до пробы по новым критериям")
    func directIPInvalidates() async {
        let harness = Harness()
        await harness.beacon.setFallback(.body(body))
        await harness.coordinator.runProbe(trigger: .startup)
        await harness.direct.enqueue(IPAddress("192.0.2.30")!)
        await harness.beacon.holdNextFetch()
        let holds = await harness.beacon.holdEvents()
        let task = Task { await harness.coordinator.refreshDirectIP() }
        #expect(await firstEvent(from: holds) != nil)
        #expect(await explanation(harness) == DetectorStatusExplanation.none)
        await harness.beacon.release()
        await task.value
        #expect(await explanation(harness) == .protected(ProtectionEvidence(expectedIP: ip, warp: .on)))
    }
}
