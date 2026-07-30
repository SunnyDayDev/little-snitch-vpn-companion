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
}
