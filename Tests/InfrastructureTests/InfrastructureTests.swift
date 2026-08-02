import Foundation
import Testing

@Suite("FileJournalStore")
struct FileJournalStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lsvpn-journal-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jsonl")
    }

    @Test("Записи переживают чтение: JSONL пишется построчно")
    func appendsAndReads() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 100),
                                        trigger: .startup,
                                        egressIP: "1.1.1.1",
                                        kind: .transition(from: .offline, to: .protected)))
        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 101),
                                        kind: .action("группа «VPN down» включена")))

        let events = await store.recent(limit: 10)
        #expect(events.count == 2)
        #expect(events.first?.egressIP == "1.1.1.1")
        #expect(events.first?.trigger == .startup)
        #expect(events.last?.kind.category == .action)
    }

    @Test("Ротация выбрасывает записи старше срока хранения")
    func rotatesOldEntries() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url, retentionDays: 7)
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date().timeIntervalSince1970
        let old = Instant(secondsSinceEpoch: now - 8 * 86_400)
        let fresh = Instant(secondsSinceEpoch: now - 3600)

        await store.append(JournalEvent(time: old, kind: .fact("древняя запись")))
        // Ротация запускается не чаще раза в час, поэтому проверяем через
        // свежий store над тем же файлом.
        let rotating = FileJournalStore(fileURL: url, retentionDays: 7)
        await rotating.append(JournalEvent(time: fresh, kind: .fact("свежая запись")))

        let events = await rotating.recent(limit: 10)
        #expect(events.count == 1)
        #expect(JournalFormatting.kind(events[0].kind) == "свежая запись")
    }

    /// Записи с новым триггером «питание» уживаются в одном файле со старыми:
    /// декодирование ProbeTrigger не сломано расширением enum.
    @Test("Записи с триггером «питание» читаются вместе со старыми")
    func powerTriggerRoundTrips() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 100),
                                        trigger: .startup,
                                        kind: .fact("старая запись")))
        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 101),
                                        trigger: .power,
                                        kind: .fact("машина засыпает")))

        let events = await store.recent(limit: 10)
        #expect(events.count == 2)
        #expect(events.last?.trigger == .power)
        #expect(JournalFormatting.trigger(.power) == "питание")
    }

    @Test("Экспорт даёт человекочитаемые строки")
    func exportsText() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 1_700_000_000),
                                        trigger: .confirmation,
                                        egressIP: "203.0.113.40",
                                        kind: .transition(from: .protected, to: .leak),
                                        action: "включена «VPN down»"))
        let text = await store.exportText()
        #expect(text.contains("Защищено → Утечка"))
        #expect(text.contains("подтверждение"))
        #expect(text.contains("203.0.113.40"))
        #expect(text.contains("включена «VPN down»"))
    }

    @Test("Очистка удаляет всё")
    func clears() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 1), kind: .fact("раз")))
        await store.clear()
        #expect(await store.recent(limit: 10).isEmpty)
    }
}

@Suite("NetworksetupWifiGateway")
struct WifiGatewayTests {
    /// Форма реального вывода с целевой машины 2026-07-29 (MAC-адреса заменены):
    /// Ethernet-адаптеры идут раньше Wi-Fi, поэтому «первый Device:» — неверный ответ.
    private let realOutput = """
        Hardware Port: Ethernet Adapter (en4)
        Device: en4
        Ethernet Address: 02:00:00:00:00:01

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 02:00:00:00:00:02

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 02:00:00:00:00:03
        """

    @Test("Находит Wi-Fi-устройство, а не первый попавшийся адаптер")
    func findsWifiDevice() {
        #expect(NetworksetupWifiGateway.parseWifiDevice(realOutput) == "en0")
    }

    @Test("Понимает старое имя порта AirPort")
    func supportsAirPortName() {
        let output = """
            Hardware Port: AirPort
            Device: en1
            Ethernet Address: 00:00:00:00:00:00
            """
        #expect(NetworksetupWifiGateway.parseWifiDevice(output) == "en1")
    }

    @Test("Без Wi-Fi-порта возвращает nil, а не догадку")
    func returnsNilWithoutWifi() {
        let output = """
            Hardware Port: Ethernet Adapter (en4)
            Device: en4
            """
        #expect(NetworksetupWifiGateway.parseWifiDevice(output) == nil)
    }
}

@Suite("RuBeaconProber")
struct RuBeaconProberTests {
    @Test("Разбирает JSON-строку yandex")
    func parsesYandexJSON() {
        #expect(RuBeaconProber.parse("\"192.0.2.10\"") == IPAddress("192.0.2.10"))
    }

    @Test("Разбирает голый text/plain 2ip.ru")
    func parsesPlainText() {
        #expect(RuBeaconProber.parse("192.0.2.10\n") == IPAddress("192.0.2.10"))
    }

    @Test("Отбрасывает всё, что не IP", arguments: [
        "<html><body>Ваш IP</body></html>", "", "\"\"", "не ip", "{\"ip\":\"1.1.1.1\"}",
    ])
    func rejectsNonIP(_ body: String) {
        #expect(RuBeaconProber.parse(body) == nil)
    }

    @Test("Требует зону .ru: иначе запрос уйдёт через VPN")
    func requiresRussianZone() {
        #expect(RuBeaconProber.isRussianZone(URL(string: "https://yandex.ru/internet/api/v0/ip")!))
        #expect(RuBeaconProber.isRussianZone(URL(string: "https://2ip.ru")!))
        #expect(!RuBeaconProber.isRussianZone(URL(string: "https://ifconfig.me")!))
        #expect(!RuBeaconProber.isRussianZone(URL(string: "https://example.ru.com")!))
    }
}

@Suite("DefaultsSettingsStore")
struct DefaultsSettingsStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "lsvpn-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("Дефолты §13 SPEC.md применяются при первом запуске")
    func appliesSpecDefaults() {
        let store = DefaultsSettingsStore(defaults: isolatedDefaults())
        let settings = store.load()

        #expect(settings.monitoringEnabled)
        #expect(!settings.observeOnly)
        #expect(settings.escalationEnabled)
        #expect(settings.heartbeatSeconds == 15)
        #expect(settings.probeSeconds == 60)
        #expect(settings.probeTimeoutSeconds == 6)
        #expect(settings.leakConfirmationSeconds == 2.5)
        #expect(settings.expectedIPs.isEmpty)
        // Группа подставляется онбордингом, только если существует в LS
        #expect(settings.leakGroups.isEmpty)
        // Список серверов пуст по умолчанию: приложение раздаётся другим
        // людям, а выходные узлы у каждого свои.
        #expect(settings.forbiddenEgressIPs.isEmpty)
        #expect(settings.ruBeaconURL == "https://yandex.ru/internet/api/v0/ip")
        #expect(settings.ruBeaconFallbackURL == "https://2ip.ru")
        #expect(settings.ruBeaconRefreshSeconds == 300)
        #expect(settings.notifyTransitions && settings.notifyErrors)
    }

    @Test("Сохранение и чтение переживают перезапуск")
    func roundTrips() {
        let defaults = isolatedDefaults()
        var settings = DefaultsSettingsStore(defaults: defaults).load()
        settings.probeSeconds = 30
        settings.leakGroups = ["VPN down", "Ещё группа"]
        settings.observeOnly = true
        DefaultsSettingsStore(defaults: defaults).save(settings)

        let reloaded = DefaultsSettingsStore(defaults: defaults).load()
        #expect(reloaded.probeSeconds == 30)
        #expect(reloaded.leakGroups == ["VPN down", "Ещё группа"])
        #expect(reloaded.observeOnly)
    }

    @Test("Абсурдные интервалы зажимаются в разумные границы")
    func clampsIntervals() {
        var settings = AppSettings()
        settings.probeSeconds = 0
        settings.heartbeatSeconds = -5
        settings.probeTimeoutSeconds = 1000
        settings.pathDebounceSeconds = .nan

        let sanitized = DefaultsSettingsStore.sanitized(settings)
        #expect(sanitized.probeSeconds == 10)
        #expect(sanitized.heartbeatSeconds == 5)
        #expect(sanitized.probeTimeoutSeconds == 30)
        #expect(sanitized.pathDebounceSeconds == 0.05)
    }

    @Test("Debug-рычаги приёмки читаются из defaults")
    func readsDebugKeys() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: DefaultsSettingsStore.Key.debugIgnoreWarp.rawValue)
        defaults.set("198.51.100.10", forKey: DefaultsSettingsStore.Key.debugFakeEgressIP.rawValue)

        let settings = DefaultsSettingsStore(defaults: defaults).load()
        #expect(settings.debugIgnoreWarp)
        #expect(settings.debugFakeEgressIP == "198.51.100.10")
        // Критерии классификации подхватывают debug-режим
        #expect(settings.criteria(directRuIP: nil).ignoreWarpForDebug)
    }
}

@Suite("Критерии из настроек")
struct SettingsCriteriaTests {
    @Test("Строки настроек превращаются в адреса, мусор отбрасывается")
    func buildsCriteria() {
        var settings = AppSettings()
        settings.expectedIPs = ["10.0.0.1", "не ip"]
        settings.forbiddenEgressIPs = ["198.51.100.10", ""]

        let criteria = settings.criteria(directRuIP: IPAddress("192.0.2.10"))
        #expect(criteria.expectedIPs == Set([IPAddress("10.0.0.1")!]))
        #expect(criteria.forbiddenServers == Set([IPAddress("198.51.100.10")!]))
        #expect(criteria.directRuIP == IPAddress("192.0.2.10"))
    }
}
