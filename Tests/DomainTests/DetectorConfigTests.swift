import Foundation
import Testing

@Suite("DetectorConfig")
struct DetectorConfigTests {
    @Test("Детектор «Основной» по умолчанию — прежнее поведение одного детектора")
    func primaryDefaults() {
        let primary = DetectorConfig.primary()
        #expect(primary.id == .primary)
        #expect(primary.name == "Основной")
        #expect(primary.isEnabled)
        #expect(primary.protectionMode == .reactive)
        #expect(primary.beacon == .cloudflare)
        #expect(primary.beacon.primaryURL == "https://www.cloudflare.com/cdn-cgi/trace")
        #expect(primary.beacon.fallbackURL == "https://1.1.1.1/cdn-cgi/trace")
        #expect(primary.beacon.format == .cdnCgiTrace)
        #expect(primary.proxy.isDirect)
        #expect(primary.warpCountsAsProtection)
        #expect(primary.tripwireEnabled)
        #expect(primary.expectedIPs.isEmpty && primary.forbiddenEgressIPs.isEmpty)
        #expect(primary.groups.isEmpty)
    }

    @Test("Новый детектор — дефолты «Основного», кроме имени и групп")
    func newDetectorDefaults() {
        let created = DetectorConfig.newDetector(id: DetectorID("x"))
        var expected = DetectorConfig.primary()
        expected.id = DetectorID("x")
        expected.name = "Новый детектор"
        #expect(created == expected)
    }

    @Test("Дублирование даёт выключенную копию «<имя> (копия)» с теми же настройками")
    func duplicateIsDisabledCopy() {
        let original = DetectorConfig(id: DetectorID("a"), name: "Через прокси",
                                      protectionMode: .strict,
                                      proxy: ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080),
                                      warpCountsAsProtection: false,
                                      expectedIPs: ["198.51.100.40"], groups: ["Telegram"])
        let copy = original.duplicated(id: DetectorID("b"))
        #expect(copy.id == DetectorID("b"))
        #expect(copy.name == "Через прокси (копия)")
        #expect(!copy.isEnabled)
        #expect(copy.proxy == original.proxy)
        #expect(copy.groups == original.groups)
        #expect(copy.protectionMode == .strict)
    }

    @Test("Критерии детектора: мусор в списках отбрасывается, флаг warp переносится")
    func buildsCriteria() {
        let detector = DetectorConfig(id: DetectorID("a"), name: "A",
                                      warpCountsAsProtection: false,
                                      expectedIPs: ["10.0.0.1", "не ip"],
                                      forbiddenEgressIPs: ["198.51.100.10", ""])
        let criteria = detector.criteria(directRuIP: IPAddress("192.0.2.10"),
                                         ignoreWarpForDebug: true)
        #expect(criteria.expectedIPs == Set([IPAddress("10.0.0.1")!]))
        #expect(criteria.forbiddenServers == Set([IPAddress("198.51.100.10")!]))
        #expect(criteria.directRuIP == IPAddress("192.0.2.10"))
        #expect(!criteria.warpCountsAsProtection)
        #expect(criteria.ignoreWarpForDebug)
    }

    // MARK: - JSON

    @Test("JSON переживает круг: прокси, маяк, правила, группы")
    func roundTripsJSON() throws {
        let detector = DetectorConfig(
            id: DetectorID("a"), name: "Через резидентный прокси", isEnabled: false,
            protectionMode: .strict,
            beacon: BeaconConfig(primaryURL: "https://example.com/ip", fallbackURL: nil,
                                 format: .plainIP),
            proxy: ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080),
            warpCountsAsProtection: false,
            expectedIPs: ["198.51.100.40"], forbiddenEgressIPs: ["203.0.113.5"],
            tripwireEnabled: false, groups: ["Telegram"])
        let data = try JSONEncoder().encode([detector])
        let decoded = try JSONDecoder().decode([DetectorConfig].self, from: data)
        #expect(decoded == [detector])
    }

    @Test("Ключи JSON — как в спеке: none/httpConnect/socks5, cdnCgiTrace/plainIP, reactive/strict")
    func encodesSpecValues() throws {
        let detector = DetectorConfig(id: DetectorID("a"), name: "A", protectionMode: .strict,
                                      proxy: ProxyConfig(kind: .httpConnect, host: "127.0.0.1",
                                                         port: 8080))
        let text = String(decoding: try JSONEncoder().encode(detector), as: UTF8.self)
        #expect(text.contains("\"httpConnect\""))
        #expect(text.contains("\"cdnCgiTrace\""))
        #expect(text.contains("\"strict\""))
        let direct = String(decoding: try JSONEncoder().encode(DetectorConfig.primary()),
                            as: UTF8.self)
        #expect(direct.contains("\"none\""))
    }

    @Test("Нераспознанный режим — реактивный, отсутствующие поля — дефолты")
    func toleratesUnknownValues() throws {
        let json = #"""
        [{"id": "a", "name": "A", "protectionMode": "paranoid",
          "proxy": {"kind": "quic", "host": "203.0.113.5", "port": 1080},
          "beacon": {"primaryURL": "https://example.com/trace", "format": "xml"}}]
        """#
        let decoded = try JSONDecoder().decode([DetectorConfig].self, from: Data(json.utf8))
        let detector = try #require(decoded.first)
        #expect(detector.protectionMode == .reactive)
        #expect(detector.proxy.isDirect)
        #expect(detector.beacon.format == .cdnCgiTrace)
        #expect(detector.beacon.fallbackURL == nil)
        #expect(detector.isEnabled)
        #expect(detector.warpCountsAsProtection)
        #expect(detector.tripwireEnabled)
        #expect(detector.groups.isEmpty)
    }

    @Test("Запись без идентификатора не читается: различать детекторы не по чему")
    func requiresID() {
        let json = #"[{"name": "A"}]"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([DetectorConfig].self, from: Data(json.utf8))
        }
    }

    // MARK: - Валидация

    @Test("Адрес прокси: хост и порт 1–65535", arguments: [
        ("203.0.113.5:1080", "203.0.113.5", 1080),
        ("proxy.example.com:8080", "proxy.example.com", 8080),
        ("[2001:db8::5]:1080", "2001:db8::5", 1080),
        ("  127.0.0.1:65535 ", "127.0.0.1", 65535),
    ])
    func parsesProxyAddress(raw: String, host: String, port: Int) throws {
        let parsed = try #require(ProxyConfig.parseAddress(raw))
        #expect(parsed.host == host)
        #expect(parsed.port == port)
    }

    @Test("Невалидный адрес прокси отвергается", arguments: [
        "203.0.113.5", "203.0.113.5:", ":1080", "203.0.113.5:0", "203.0.113.5:65536",
        "203.0.113.5:80a", "2001:db8::5:1080", "[2001:db8::5]1080", "host name:80", "",
    ])
    func rejectsProxyAddress(raw: String) {
        #expect(ProxyConfig.parseAddress(raw) == nil)
    }

    @Test("Адрес прокси для показа: IPv6 в скобках")
    func formatsProxyAddress() {
        #expect(ProxyConfig(kind: .socks5, host: "203.0.113.5", port: 1080).address
            == "203.0.113.5:1080")
        #expect(ProxyConfig(kind: .socks5, host: "2001:db8::5", port: 1080).address
            == "[2001:db8::5]:1080")
        #expect(ProxyConfig.direct.address.isEmpty)
    }

    @Test("URL маяка: только http(s) с хостом", arguments: [
        ("https://www.cloudflare.com/cdn-cgi/trace", true),
        ("http://192.0.2.10/ip", true),
        ("HTTPS://example.com", true),
        ("https://[2001:db8::1]/cdn-cgi/trace", true),
        ("ftp://example.com", false),
        ("example.com/cdn-cgi/trace", false),
        ("https://", false),
        ("https:///path", false),
        ("https://exa mple.com", false),
        ("", false),
    ])
    func validatesBeaconURL(raw: String, valid: Bool) {
        #expect(BeaconConfig.isValidURL(raw) == valid)
    }
}
