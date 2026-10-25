import Testing

/// Таблица §4.1 SPEC.md — каждая строка покрыта тестом.
@Suite("EgressClassifier")
struct EgressClassifierTests {
    private let cloudflareIP = IPAddress("2a09:bac5:4c9c:18f8::3f")!
    private let foreignIP = IPAddress("203.0.113.40")!
    private let serverIP = IPAddress("198.51.100.10")!
    private let directRuIP = IPAddress("198.51.100.20")!

    private func trace(_ ip: IPAddress, _ warp: WarpStatus) -> BeaconTrace {
        BeaconTrace(ip: ip, warp: warp, colo: "AMS", loc: "NL")
    }

    @Test("warp=on и адрес не запрещён → protected")
    func warpOnIsProtected() {
        let result = EgressClassifier.classify(trace(cloudflareIP, .on),
                                               criteria: EgressCriteria())
        #expect(result == .protected(trace(cloudflareIP, .on)))
    }

    @Test("warp=plus тоже защищён")
    func warpPlusIsProtected() {
        let result = EgressClassifier.classify(trace(cloudflareIP, .plus),
                                               criteria: EgressCriteria())
        if case .protected = result {} else { Issue.record("ожидался protected") }
    }

    @Test("warp=off и адрес из EXPECTED_IPS → protected")
    func expectedIPIsProtected() {
        var criteria = EgressCriteria()
        criteria.expectedIPs = [foreignIP]
        let result = EgressClassifier.classify(trace(foreignIP, .off), criteria: criteria)
        if case .protected = result {} else { Issue.record("ожидался protected") }
    }

    @Test("warp=off и чужой адрес → leak-кандидат")
    func foreignEgressIsLeak() {
        let result = EgressClassifier.classify(trace(foreignIP, .off),
                                               criteria: EgressCriteria())
        #expect(result == .leakCandidate(trace(foreignIP, .off), .foreignEgress))
    }

    @Test("Сервер инфраструктуры в egress → leak даже при warp=on")
    func forbiddenServerBeatsWarp() {
        var criteria = EgressCriteria()
        criteria.forbiddenServers = [serverIP]
        let result = EgressClassifier.classify(trace(serverIP, .on), criteria: criteria)
        #expect(result == .leakCandidate(trace(serverIP, .on), .forbiddenServer(serverIP)))
    }

    @Test("Прямой РУ-IP в egress → leak с диагнозом полного обхода")
    func directRuIPIsFullBypass() {
        var criteria = EgressCriteria()
        criteria.directRuIP = directRuIP
        let result = EgressClassifier.classify(trace(directRuIP, .on), criteria: criteria)
        #expect(result == .leakCandidate(trace(directRuIP, .on), .directRuIP(directRuIP)))
    }

    @Test("EXPECTED_IPS не перевешивает denylist")
    func denylistBeatsAllowlist() {
        var criteria = EgressCriteria()
        criteria.expectedIPs = [serverIP]
        criteria.forbiddenServers = [serverIP]
        let result = EgressClassifier.classify(trace(serverIP, .off), criteria: criteria)
        #expect(result == .leakCandidate(trace(serverIP, .off), .forbiddenServer(serverIP)))
    }

    @Test("Debug-режим игнорирования warp=on даёт leak (сценарий 2 §14)")
    func debugIgnoreWarp() {
        var criteria = EgressCriteria()
        criteria.ignoreWarpForDebug = true
        let result = EgressClassifier.classify(trace(cloudflareIP, .on), criteria: criteria)
        #expect(result == .leakCandidate(trace(cloudflareIP, .on), .foreignEgress))
    }

    @Test("Ответ маяка разбирается целиком")
    func parsesTraceBody() throws {
        let body = """
        fl=123abc
        ip=2a09:bac5:4c9c:18f8::3f
        ts=1753900000.123
        warp=on
        colo=AMS
        loc=NL
        """
        let parsed = try #require(TraceParser.parse(body))
        #expect(parsed.ip == cloudflareIP)
        #expect(parsed.warp == .on)
        #expect(parsed.colo == "AMS")
        #expect(parsed.loc == "NL")
    }

    @Test("Тело без ip= (captive portal) → offline")
    func bodyWithoutIPIsOffline() {
        let result = EgressClassifier.classifyBody("<html>login required</html>",
                                                   criteria: EgressCriteria())
        #expect(result == .offline(.unparsableResponse))
    }

    @Test("Отсутствие warp= трактуется как неизвестный статус → leak")
    func missingWarpIsUnknown() {
        let result = EgressClassifier.classifyBody("ip=203.0.113.40\ncolo=DME",
                                                   criteria: EgressCriteria())
        #expect(result == .leakCandidate(BeaconTrace(ip: foreignIP, warp: .unknown, colo: "DME"),
                                         .foreignEgress))
    }

    // MARK: - Правила детектора (дельта egress-detection)

    @Test("Флаг «warp=on считается защитой» выключен: warp=on с чужим адресом → leak")
    func warpFlagOffMakesWarpForeign() {
        var criteria = EgressCriteria()
        criteria.warpCountsAsProtection = false
        let result = EgressClassifier.classify(trace(cloudflareIP, .on), criteria: criteria)
        #expect(result == .leakCandidate(trace(cloudflareIP, .on), .foreignEgress))
    }

    @Test("Флаг выключен, но адрес из EXPECTED_IPS → protected при warp=on")
    func warpFlagOffStillHonoursExpected() {
        var criteria = EgressCriteria()
        criteria.warpCountsAsProtection = false
        criteria.expectedIPs = [cloudflareIP]
        let result = EgressClassifier.classify(trace(cloudflareIP, .on), criteria: criteria)
        #expect(result == .protected(trace(cloudflareIP, .on)))
    }

    @Test("Флаг выключен: запрещённый адрес по-прежнему даёт диагноз сервера")
    func warpFlagOffKeepsDenylistDiagnosis() {
        var criteria = EgressCriteria()
        criteria.warpCountsAsProtection = false
        criteria.forbiddenServers = [serverIP]
        let result = EgressClassifier.classify(trace(serverIP, .on), criteria: criteria)
        #expect(result == .leakCandidate(trace(serverIP, .on), .forbiddenServer(serverIP)))
    }

    @Test("Ответ без warp= с адресом из EXPECTED_IPS → protected")
    func missingWarpWithExpectedIsProtected() {
        var criteria = EgressCriteria()
        criteria.expectedIPs = [foreignIP]
        let result = EgressClassifier.classifyBody("ip=203.0.113.40\ncolo=DME",
                                                   criteria: criteria)
        #expect(result == .protected(BeaconTrace(ip: foreignIP, warp: .unknown, colo: "DME")))
    }

    @Test("Голый IP из EXPECTED_IPS → protected, warp неизвестен")
    func plainIPExpectedIsProtected() {
        var criteria = EgressCriteria()
        criteria.expectedIPs = [IPAddress("198.51.100.40")!]
        let result = EgressClassifier.classifyBody("\"198.51.100.40\"", format: .plainIP,
                                                   criteria: criteria)
        #expect(result == .protected(BeaconTrace(ip: IPAddress("198.51.100.40")!, warp: .unknown)))
    }

    @Test("Голый IP вне правил → leak: правило warp для него не выполняется никогда")
    func plainIPForeignIsLeak() {
        let result = EgressClassifier.classifyBody("203.0.113.40", format: .plainIP,
                                                   criteria: EgressCriteria())
        #expect(result == .leakCandidate(BeaconTrace(ip: foreignIP, warp: .unknown), .foreignEgress))
    }

    @Test("Голый IP из запрещённых → leak с диагнозом сервера")
    func plainIPForbiddenIsLeak() {
        var criteria = EgressCriteria()
        criteria.forbiddenServers = [serverIP]
        let result = EgressClassifier.classifyBody("198.51.100.10\n", format: .plainIP,
                                                   criteria: criteria)
        #expect(result == .leakCandidate(BeaconTrace(ip: serverIP, warp: .unknown),
                                         .forbiddenServer(serverIP)))
    }

    @Test("Маяк формата «голый IP» вернул HTML → offline")
    func plainIPHTMLIsOffline() {
        let result = EgressClassifier.classifyBody("<html>Ваш IP</html>", format: .plainIP,
                                                   criteria: EgressCriteria())
        #expect(result == .offline(.unparsableResponse))
    }

    @Test("Голый IP в формате cdn-cgi/trace не разбирается → offline")
    func plainBodyUnderTraceFormatIsOffline() {
        let result = EgressClassifier.classifyBody("203.0.113.40", format: .cdnCgiTrace,
                                                   criteria: EgressCriteria())
        #expect(result == .offline(.unparsableResponse))
    }

    @Test("Правила двух детекторов независимы: один и тот же egress — разные вердикты")
    func detectorsRulesAreIndependent() {
        let detectorA = DetectorConfig(id: DetectorID("a"), name: "A",
                                       warpCountsAsProtection: false,
                                       expectedIPs: ["203.0.113.40"])
        let detectorB = DetectorConfig(id: DetectorID("b"), name: "B",
                                       warpCountsAsProtection: false)
        let egress = trace(foreignIP, .off)

        let resultA = EgressClassifier.classify(egress, criteria: detectorA.criteria(directRuIP: nil))
        let resultB = EgressClassifier.classify(egress, criteria: detectorB.criteria(directRuIP: nil))

        #expect(resultA == .protected(egress))
        #expect(resultB == .leakCandidate(egress, .foreignEgress))
    }

    @Test("Прямой IP сети общий: попадает в запрещённые любого детектора")
    func directRuIPAppliesToEveryDetector() {
        let detector = DetectorConfig(id: DetectorID("a"), name: "A",
                                      expectedIPs: ["198.51.100.20"])
        let result = EgressClassifier.classify(
            trace(directRuIP, .off), criteria: detector.criteria(directRuIP: directRuIP))
        #expect(result == .leakCandidate(trace(directRuIP, .off), .directRuIP(directRuIP)))
    }

    @Test("Глобальный debugIgnoreWarp накладывается на флаг детектора через И",
          arguments: [(true, false, true), (true, true, false),
                      (false, false, false), (false, true, false)])
    func debugLeverCombinesWithFlag(flag: Bool, debug: Bool, protected: Bool) {
        let detector = DetectorConfig(id: DetectorID("a"), name: "A",
                                      warpCountsAsProtection: flag)
        let result = EgressClassifier.classify(
            trace(cloudflareIP, .on),
            criteria: detector.criteria(directRuIP: nil, ignoreWarpForDebug: debug))
        if protected {
            #expect(result == .protected(trace(cloudflareIP, .on)))
        } else {
            #expect(result == .leakCandidate(trace(cloudflareIP, .on), .foreignEgress))
        }
    }
}

/// Разбор ответа маяка по формату (D4 design.md) и голого IP РУ-маяка.
@Suite("Разбор ответа маяка")
struct BeaconResponseParserTests {
    @Test("JSON-строка с IP разбирается")
    func parsesJSONString() {
        #expect(PlainIPParser.parse("\"198.51.100.40\"") == IPAddress("198.51.100.40"))
        #expect(BeaconResponseParser.parse("\"198.51.100.40\"\n", format: .plainIP)
            == BeaconTrace(ip: IPAddress("198.51.100.40")!, warp: .unknown))
    }

    @Test("Голый IPv4 и IPv6 с переводом строки разбираются")
    func parsesBareAddresses() {
        #expect(PlainIPParser.parse("192.0.2.10\n") == IPAddress("192.0.2.10"))
        #expect(PlainIPParser.parse("  2001:db8::40\r\n") == IPAddress("2001:db8::40"))
        #expect(BeaconResponseParser.parse("2001:db8::40", format: .plainIP)?.ip
            == IPAddress("2001:db8:0:0:0:0:0:40"))
    }

    @Test("Отбрасывает всё, что не IP", arguments: [
        "<html><body>Ваш IP</body></html>", "", "\"\"", "не ip", "{\"ip\":\"192.0.2.10\"}",
    ])
    func rejectsNonIP(_ body: String) {
        #expect(PlainIPParser.parse(body) == nil)
        #expect(BeaconResponseParser.parse(body, format: .plainIP) == nil)
    }

    @Test("Trace с другого домена за Cloudflare разбирается по тем же полям")
    func parsesTraceFromAnyCloudflareDomain() {
        let body = "fl=1\nh=example.com\nip=192.0.2.10\nwarp=off\ncolo=AMS\n"
        #expect(BeaconResponseParser.parse(body, format: .cdnCgiTrace)
            == BeaconTrace(ip: IPAddress("192.0.2.10")!, warp: .off, colo: "AMS"))
    }
}
