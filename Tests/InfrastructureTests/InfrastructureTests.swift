import Foundation
import Network
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

    @Test("Поле «детектор» пишется в JSONL и показывается префиксом")
    func detectorFieldRoundTrips() async {
        let url = temporaryURL()
        let store = FileJournalStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 1_700_000_000),
                                        trigger: .scheduled,
                                        detector: "Через резидентный прокси",
                                        egressIP: "203.0.113.40",
                                        kind: .transition(from: .protected, to: .leak)))
        let events = await store.recent(limit: 10)
        #expect(events.first?.detector == "Через резидентный прокси")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(raw.contains("\"detector\":\"Через резидентный прокси\""))
        let text = await store.exportText()
        #expect(text.contains("[Через резидентный прокси] Защищено → Утечка"))
    }

    @Test("Записи прежних версий без поля «детектор» читаются как есть")
    func readsLegacyRecordsWithoutDetector() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        // Строка в формате прежней версии: поля detector нет вовсе
        let legacy = #"{"time":{"secondsSinceEpoch":1700000000},"trigger":"scheduled","egressIP":"203.0.113.40","kind":{"fact":{"_0":"старая запись"}}}"#
        try (legacy + "\n").write(to: url, atomically: true, encoding: .utf8)

        let store = FileJournalStore(fileURL: url)
        let events = await store.recent(limit: 10)
        #expect(events.count == 1)
        #expect(events.first?.detector == nil)
        #expect(JournalFormatting.event(events[0]) == "старая запись")
        // Новая запись без детектора поля не получает: события общих слоёв
        await store.append(JournalEvent(time: Instant(secondsSinceEpoch: 1_700_000_001),
                                        trigger: .path, kind: .fact("сеть пропала")))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("detector"))
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
    // Разбор ответа (JSON-строка yandex, голый IP ip.beget.ru) — доменный
    // `PlainIPParser`, его таблица — в DomainTests.

    @Test("Сессия РУ-маяка — напрямую: без системного прокси и прокси детекторов")
    func sessionIsDirect() {
        let configuration = RuBeaconProber.sessionConfiguration(timeout: 6)
        #expect(configuration.proxyConfigurations.isEmpty)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCache == nil)
    }

    @Test("Резервный РУ-маяк по умолчанию — в зоне .ru")
    func defaultFallbackIsRussianZone() {
        #expect(RuBeaconProber.isRussianZone(URL(string: AppSettings().ruBeaconFallbackURL)!))
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
        // Один детектор «Основной»: группа подставляется онбордингом, только
        // если существует в LS; серверов нет — у каждого свои.
        #expect(settings.detectors == [.primary()])
        #expect(settings.ruBeaconURL == "https://yandex.ru/internet/api/v0/ip")
        #expect(settings.ruBeaconFallbackURL == "https://ip.beget.ru")
        #expect(settings.ruBeaconRefreshSeconds == 300)
        #expect(settings.notifyTransitions && settings.notifyErrors)
    }

    @Test("Сохранение и чтение переживают перезапуск")
    func roundTrips() {
        let defaults = isolatedDefaults()
        var settings = DefaultsSettingsStore(defaults: defaults).load()
        settings.probeSeconds = 30
        settings.detectors[0].groups = ["VPN down", "Ещё группа"]
        settings.observeOnly = true
        DefaultsSettingsStore(defaults: defaults).save(settings)

        let reloaded = DefaultsSettingsStore(defaults: defaults).load()
        #expect(reloaded.probeSeconds == 30)
        #expect(reloaded.detectors[0].groups == ["VPN down", "Ещё группа"])
        #expect(reloaded.observeOnly)
    }

    @Test("Детектор с SOCKS5-прокси переживает перезапуск")
    func detectorRoundTrips() {
        let defaults = isolatedDefaults()
        var settings = DefaultsSettingsStore(defaults: defaults).load()
        let proxied = DetectorConfig(
            id: DetectorID("B5F2A1C4-0000-4000-8000-000000000002"),
            name: "Через резидентный прокси", protectionMode: .strict,
            beacon: BeaconConfig(primaryURL: "https://example.com/cdn-cgi/trace",
                                 fallbackURL: nil, format: .cdnCgiTrace),
            proxy: ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080),
            warpCountsAsProtection: false,
            expectedIPs: ["198.51.100.40"], forbiddenEgressIPs: ["203.0.113.5"],
            tripwireEnabled: false, groups: ["Telegram"])
        settings.detectors.append(proxied)
        DefaultsSettingsStore(defaults: defaults).save(settings)

        let reloaded = DefaultsSettingsStore(defaults: defaults).load()
        #expect(reloaded.detectors.count == 2)
        #expect(reloaded.detectors.last == proxied)
    }

    @Test("Мёртвый резервный РУ-маяк прежних версий заменяется текущим дефолтом")
    func replacesLegacyRuFallback() {
        let defaults = isolatedDefaults()
        defaults.set("https://2ip.ru", forKey: DefaultsSettingsStore.Key.ruBeaconFallbackURL.rawValue)
        #expect(DefaultsSettingsStore(defaults: defaults).load().ruBeaconFallbackURL
            == "https://ip.beget.ru")
        // Своё значение пользователя не трогается
        defaults.set("https://example.ru/ip", forKey: DefaultsSettingsStore.Key.ruBeaconFallbackURL.rawValue)
        #expect(DefaultsSettingsStore(defaults: defaults).load().ruBeaconFallbackURL
            == "https://example.ru/ip")
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

    @Test("Санитизация детектора: порт прокси, URL маяков, имя, повтор идентификатора")
    func sanitizesDetectors() {
        var settings = AppSettings()
        var broken = DetectorConfig(id: DetectorID("x"), name: "   ")
        broken.proxy = ProxyConfig(kind: .httpConnect, host: " 127.0.0.1 ", port: 70_000)
        broken.beacon.primaryURL = "ftp://example.com"
        broken.beacon.fallbackURL = "не url"
        var duplicate = DetectorConfig(id: DetectorID("x"), name: "Дубль")
        duplicate.isEnabled = false
        settings.detectors = [broken, duplicate]

        let sanitized = DefaultsSettingsStore.sanitized(settings)
        #expect(sanitized.detectors.count == 1)
        let detector = sanitized.detectors[0]
        #expect(detector.name == "Без названия")
        #expect(detector.proxy.port == 65_535)
        #expect(detector.proxy.host == "127.0.0.1")
        #expect(detector.proxy.kind == .httpConnect)
        #expect(detector.beacon.primaryURL == BeaconConfig.cloudflare.primaryURL)
        #expect(detector.beacon.fallbackURL == nil)
    }

    @Test("Debug-рычаги приёмки читаются из defaults и действуют на все детекторы")
    func readsDebugKeys() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: DefaultsSettingsStore.Key.debugIgnoreWarp.rawValue)
        defaults.set("198.51.100.10", forKey: DefaultsSettingsStore.Key.debugFakeEgressIP.rawValue)

        var settings = DefaultsSettingsStore(defaults: defaults).load()
        settings.detectors.append(.newDetector(id: DetectorID("второй")))
        #expect(settings.debugIgnoreWarp)
        #expect(settings.debugFakeEgressIP == "198.51.100.10")
        // Критерии классификации каждого детектора подхватывают debug-режим
        for detector in settings.detectors {
            #expect(settings.criteria(for: detector, directRuIP: nil).ignoreWarpForDebug)
        }
    }

    // MARK: - Миграция настроек одного детектора

    private func legacyDefaults() -> UserDefaults {
        let defaults = isolatedDefaults()
        defaults.set(["VPN down"], forKey: "leakGroups")
        defaults.set(["192.0.2.10"], forKey: "expectedIPs")
        defaults.set(["198.51.100.10"], forKey: "forbiddenEgressIPs")
        defaults.set("strict", forKey: "protectionMode")
        return defaults
    }

    @Test("Обновление: старые ключи собираются в «Основной», массив записан")
    func migratesLegacyKeys() throws {
        let defaults = legacyDefaults()
        let store = DefaultsSettingsStore(defaults: defaults)

        let outcome = store.prepareDetectors()

        var expected = DetectorConfig.primary()
        expected.protectionMode = .strict
        expected.expectedIPs = ["192.0.2.10"]
        expected.forbiddenEgressIPs = ["198.51.100.10"]
        expected.groups = ["VPN down"]
        #expect(outcome == .migrated(expected))
        #expect(store.load().detectors == [expected])
        // Массив записан одним ключом — второй запуск миграцию не повторяет
        #expect(defaults.string(forKey: "detectors") != nil)
        #expect(DefaultsSettingsStore(defaults: defaults).prepareDetectors() == .stored)
        // Поведение прежнее: без прокси, маяк Cloudflare, warp=on — защита
        let primary = try #require(store.load().detectors.first)
        #expect(primary.proxy.isDirect)
        #expect(primary.beacon == .cloudflare)
        #expect(primary.warpCountsAsProtection && primary.tripwireEnabled)
    }

    @Test("Откат: старые ключи не тронуты ни миграцией, ни сохранением")
    func keepsLegacyKeysForRollback() {
        let defaults = legacyDefaults()
        let store = DefaultsSettingsStore(defaults: defaults)
        store.prepareDetectors()
        var settings = store.load()
        settings.detectors[0].groups = ["Другая группа"]
        settings.detectors[0].protectionMode = .reactive
        store.save(settings)

        #expect(defaults.stringArray(forKey: "leakGroups") == ["VPN down"])
        #expect(defaults.stringArray(forKey: "expectedIPs") == ["192.0.2.10"])
        #expect(defaults.stringArray(forKey: "forbiddenEgressIPs") == ["198.51.100.10"])
        #expect(defaults.string(forKey: "protectionMode") == "strict")
    }

    @Test("Нераспознанный прежний режим мигрирует в реактивный")
    func migratesUnknownModeAsReactive() {
        let defaults = isolatedDefaults()
        defaults.set("paranoid", forKey: "protectionMode")
        let outcome = DefaultsSettingsStore(defaults: defaults).prepareDetectors()
        guard case .migrated(let primary) = outcome else {
            Issue.record("ожидалась миграция")
            return
        }
        #expect(primary.protectionMode == .reactive)
    }

    @Test("Чистая установка: «Основной» по дефолтам, записи о миграции нет")
    func freshInstall() {
        let defaults = isolatedDefaults()
        let store = DefaultsSettingsStore(defaults: defaults)
        #expect(store.prepareDetectors() == .freshInstall)
        #expect(store.load().detectors == [.primary()])
        // Ничего не записано: первое изменение настроек запишет массив
        #expect(defaults.object(forKey: "detectors") == nil)
    }

    @Test("Повреждённый массив: дефолт и предупреждение, значение не перезаписано")
    func corruptedDetectors() {
        let defaults = isolatedDefaults()
        defaults.set("[{\"id\": ", forKey: "detectors")
        let store = DefaultsSettingsStore(defaults: defaults)

        guard case .corrupted = store.prepareDetectors() else {
            Issue.record("ожидалось повреждение")
            return
        }
        #expect(store.load().detectors == [.primary()])
        #expect(defaults.string(forKey: "detectors") == "[{\"id\": ")
    }

    @Test("Массив не той формы — тоже повреждение")
    func wrongShapeIsCorrupted() {
        let defaults = isolatedDefaults()
        defaults.set(["не", "json"], forKey: "detectors")
        guard case .corrupted = DefaultsSettingsStore(defaults: defaults).prepareDetectors() else {
            Issue.record("ожидалось повреждение")
            return
        }
    }

    @Test("Пустой массив детекторов допустим")
    func emptyDetectorsAllowed() {
        let defaults = isolatedDefaults()
        var settings = DefaultsSettingsStore(defaults: defaults).load()
        settings.detectors = []
        DefaultsSettingsStore(defaults: defaults).save(settings)
        #expect(DefaultsSettingsStore(defaults: defaults).load().detectors.isEmpty)
    }
}

@Suite("Критерии и failsafe из настроек")
struct SettingsCriteriaTests {
    @Test("Строки детектора превращаются в адреса, мусор отбрасывается")
    func buildsCriteria() {
        var settings = AppSettings()
        settings.detectors[0].expectedIPs = ["10.0.0.1", "не ip"]
        settings.detectors[0].forbiddenEgressIPs = ["198.51.100.10", ""]

        let criteria = settings.criteria(for: settings.detectors[0],
                                         directRuIP: IPAddress("192.0.2.10"))
        #expect(criteria.expectedIPs == Set([IPAddress("10.0.0.1")!]))
        #expect(criteria.forbiddenServers == Set([IPAddress("198.51.100.10")!]))
        #expect(criteria.directRuIP == IPAddress("192.0.2.10"))
    }
}

/// Путь пробы и растяжки детектора: прокси через `ProxyConfiguration`,
/// без системных настроек прокси.
@Suite("Прокси детектора")
struct ProxyRoutingTests {
    @Test("Без прокси: прямой путь, системный прокси выключен пустым словарём")
    func directIgnoresSystemProxy() {
        let configuration = BeaconProber.sessionConfiguration(proxy: .direct, timeout: 6)
        #expect(configuration.proxyConfigurations.isEmpty)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForRequest == 6)
    }

    @Test("SOCKS5 и HTTP CONNECT дают одну конфигурацию без отката на прямой путь",
          arguments: [ProxyConfig.Kind.socks5, .httpConnect])
    func proxiedSession(kind: ProxyConfig.Kind) throws {
        let proxy = ProxyConfig(kind: kind, host: "203.0.113.5", port: 1080)
        let configuration = BeaconProber.sessionConfiguration(proxy: proxy, timeout: 6)
        let proxies = configuration.proxyConfigurations
        #expect(proxies.count == 1)
        let only = try #require(proxies.first)
        #expect(!only.allowFailover)
        #expect(only.debugDescription.contains("203.0.113.5"))
        #expect(only.debugDescription.contains("1080"))
    }

    @Test("Прокси без адреса или с портом 0 конфигурации не даёт")
    func incompleteProxyHasNoEndpoint() {
        #expect(ProxyRouting.endpoint(for: ProxyConfig(kind: .socks5, host: "", port: 1080)) == nil)
        #expect(ProxyRouting.endpoint(for: ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 0)) == nil)
        #expect(ProxyRouting.endpoint(for: ProxyConfig(kind: .direct, host: "203.0.113.5", port: 1080)) == nil)
    }

    @Test("NWParameters: без прокси — preferNoProxies")
    func directParametersPreferNoProxies() {
        let parameters = NWParameters.tls
        ProxyRouting.apply(.direct, to: parameters)
        #expect(parameters.preferNoProxies)
    }

    @Test("Проба через прокси без адреса — Offline без похода в сеть")
    func incompleteProxyProbeIsOffline() async {
        var detector = DetectorConfig.primary()
        detector.proxy = ProxyConfig(kind: .socks5, host: "", port: 1080)
        let result = await BeaconProber().fetchTrace(for: detector, timeout: 1)
        #expect(result == .offline(.networkFailure))
    }

    @Test("Отказ прокси — Offline, не утечка", arguments: [
        NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
        NSError(domain: kCFErrorDomainCFNetwork as String, code: 110),
        NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired),
    ])
    func proxyFailureIsOffline(error: NSError) {
        #expect(BeaconProber.classify(error) == .networkFailure)
    }

    @Test("Таймаут прокси — Offline по таймауту")
    func proxyTimeoutIsTimeout() {
        #expect(BeaconProber.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
            == .timeout)
    }

    @Test("Debug-подмена egress — в формате маяка детектора")
    func debugFakeFollowsFormat() async {
        var configured = AppSettings()
        configured.debugFakeEgressIP = "198.51.100.10"
        let settings = configured
        let prober = BeaconProber(settingsProvider: { settings })
        var plain = DetectorConfig.primary()
        plain.beacon.format = .plainIP
        #expect(await prober.fetchTrace(for: plain, timeout: 1) == .body("198.51.100.10"))
        let trace = await prober.fetchTrace(for: .primary(), timeout: 1)
        guard case .body(let body) = trace else {
            Issue.record("ожидалось тело")
            return
        }
        #expect(TraceParser.parse(body)?.ip == IPAddress("198.51.100.10"))
    }
}

/// Растяжка ходит на хост основного маяка детектора и шлёт heartbeat по его
/// пути (D6 design.md).
@Suite("Растяжка детектора")
struct TripwireTargetTests {
    @Test("Маяк Cloudflare по умолчанию — прежний heartbeat")
    func defaultCloudflare() throws {
        let target = try #require(TripwireTarget(beaconURL: "https://www.cloudflare.com/cdn-cgi/trace"))
        #expect(target.host == "www.cloudflare.com")
        #expect(target.port == 443)
        #expect(target.usesTLS)
        #expect(target.heartbeatRequest == "GET /cdn-cgi/trace HTTP/1.1\r\n"
            + "Host: www.cloudflare.com\r\n"
            + "User-Agent: LSVPNCompanion/1.0\r\n"
            + "Connection: keep-alive\r\n\r\n")
    }

    @Test("Другой домен, нестандартный порт и запрос с query")
    func customBeacon() throws {
        let target = try #require(TripwireTarget(beaconURL: "https://example.com:8443/ip?format=text"))
        #expect(target.host == "example.com")
        #expect(target.port == 8443)
        #expect(target.path == "/ip?format=text")
        #expect(target.hostHeader == "example.com:8443")
        #expect(target.heartbeatRequest.hasPrefix("GET /ip?format=text HTTP/1.1\r\nHost: example.com:8443\r\n"))
    }

    @Test("Маяк по IP, без пути и по http")
    func ipAndPlainHTTP() throws {
        let fallback = try #require(TripwireTarget(beaconURL: "https://1.1.1.1/cdn-cgi/trace"))
        #expect(fallback.host == "1.1.1.1")
        let plain = try #require(TripwireTarget(beaconURL: "http://192.0.2.10"))
        #expect(plain.port == 80)
        #expect(!plain.usesTLS)
        #expect(plain.path == "/")
        #expect(plain.hostHeader == "192.0.2.10")
    }

    @Test("IPv6-хост — в скобках в заголовке Host")
    func ipv6Host() throws {
        let target = try #require(TripwireTarget(beaconURL: "https://[2001:db8::1]/cdn-cgi/trace"))
        #expect(target.host == "2001:db8::1")
        #expect(target.hostHeader == "[2001:db8::1]")
    }

    @Test("Не URL маяка — растяжки нет", arguments: ["", "ftp://example.com/x", "не url"])
    func rejectsNonBeacon(raw: String) {
        #expect(TripwireTarget(beaconURL: raw) == nil)
    }
}

/// Ответ helper о группах читается и без поля `kind` (старый демон, запасной
/// разбор модели), и с незнакомым значением: вид становится неизвестным, а
/// не ошибкой — список групп важнее подписи.
@Suite("Разбор ответа helper о группах")
struct HelperRuleGroupDecodingTests {
    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    @Test("Поле kind отображается в вид группы")
    func decodesKind() throws {
        let groups = try HelperRuleGroupDecoding.decode(json("""
        [{"name": "Require VPN Services", "enabled": false, "kind": "remote"},
         {"name": "macOS Services", "enabled": true, "kind": "builtin"},
         {"name": "VPN down", "enabled": true, "kind": "local"}]
        """))
        #expect(groups == [
            RuleGroup(name: "Require VPN Services", enabled: false, kind: .remote),
            RuleGroup(name: "macOS Services", enabled: true, kind: .builtin),
            RuleGroup(name: "VPN down", enabled: true, kind: .local),
        ])
    }

    @Test("Ответ без kind читается, вид неизвестен")
    func toleratesMissingKind() throws {
        let groups = try HelperRuleGroupDecoding.decode(json(
            #"[{"name": "VPN down", "enabled": true}]"#))
        #expect(groups == [RuleGroup(name: "VPN down", enabled: true)])
        #expect(groups.first?.kind == nil)
    }

    @Test("Незнакомое значение kind — не ошибка")
    func toleratesUnknownKind() throws {
        let groups = try HelperRuleGroupDecoding.decode(json(
            #"[{"name": "Ads", "enabled": true, "kind": "blocklist"}]"#))
        #expect(groups == [RuleGroup(name: "Ads", enabled: true)])
    }
}

@Suite("DefaultsHelperInstallFacts")
struct DefaultsHelperInstallFactsTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lsvpn-tests-\(UUID().uuidString)")!
    }

    @Test("Флаг «удалён пользователем» переживает перечитывание и по умолчанию снят")
    func roundTripsRemovalFlag() {
        let defaults = isolatedDefaults()
        #expect(!DefaultsHelperInstallFacts(defaults: defaults).removedByUser)

        DefaultsHelperInstallFacts(defaults: defaults).setRemovedByUser(true)
        #expect(DefaultsHelperInstallFacts(defaults: defaults).removedByUser)

        DefaultsHelperInstallFacts(defaults: defaults).setRemovedByUser(false)
        #expect(!DefaultsHelperInstallFacts(defaults: defaults).removedByUser)
    }
}
