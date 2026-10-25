import Testing

@Suite("Guard прямого РУ-IP")
struct DirectIPGuardTests {
    private let cloudflare = IPAddress("2a09:bac5::3f")!
    private let providerIP = IPAddress("203.0.113.40")!
    private let proxyExit = IPAddress("198.51.100.40")!

    private func verdict(_ ip: IPAddress, _ warp: WarpStatus,
                         expected: Set<IPAddress> = [],
                         warpCounts: Bool = true) -> DirectIPGuard.Verdict {
        DirectIPGuard.Verdict(trace: BeaconTrace(ip: ip, warp: warp),
                              expectedIPs: expected,
                              warpCountsAsProtection: warpCounts)
    }

    @Test("Обычный ответ РУ-маяка принимается в denylist")
    func acceptsNormalAnswer() {
        let decision = DirectIPGuard.evaluate(candidate: providerIP,
                                              verdicts: [verdict(cloudflare, .on)])
        #expect(decision == .accept(providerIP))
    }

    @Test("Совпадение с protected-egress отвергается: РУ-маяк ушёл через VPN")
    func rejectsWhenMatchesProtectedEgress() {
        let decision = DirectIPGuard.evaluate(candidate: cloudflare,
                                              verdicts: [verdict(cloudflare, .on)])
        #expect(decision == .rejectMatchesProtectedEgress(cloudflare))
    }

    /// Регрессия: guard раньше смотрел на состояние машины, поэтому в Offline,
    /// Leak и Paused вырожденный ответ принимался и отравлял denylist —
    /// приложение назначало себе вечную утечку.
    @Test("Отвергает независимо от состояния — критерий в ответе маяка, а не в состоянии")
    func rejectsRegardlessOfState() {
        // warp=plus — тоже защищённый egress
        #expect(DirectIPGuard.evaluate(candidate: cloudflare,
                                       verdicts: [verdict(cloudflare, .plus)])
            == .rejectMatchesProtectedEgress(cloudflare))
        // Адрес из EXPECTED_IPS при warp=off тоже считается защищённым
        #expect(DirectIPGuard.evaluate(candidate: providerIP,
                                       verdicts: [verdict(providerIP, .off, expected: [providerIP])])
            == .rejectMatchesProtectedEgress(providerIP))
    }

    @Test("При реальной утечке egress и есть прямой IP — адрес принимается")
    func acceptsDuringRealLeak() {
        // warp=off и адрес не из ожидаемых: это утечка, а не наш egress
        let decision = DirectIPGuard.evaluate(candidate: providerIP,
                                              verdicts: [verdict(providerIP, .off)])
        #expect(decision == .accept(providerIP))
    }

    @Test("Без вердикта ни одного детектора решение откладывается")
    func defersWithoutVerdict() {
        let decision = DirectIPGuard.evaluate(candidate: providerIP, verdicts: [])
        #expect(decision == .deferUntilFirstVerdict(providerIP))
    }

    // MARK: - Несколько детекторов

    @Test("Совпадение с защищённым ответом одного из двух детекторов отвергается")
    func rejectsWhenMatchesAnyDetector() {
        let decision = DirectIPGuard.evaluate(candidate: proxyExit, verdicts: [
            verdict(cloudflare, .on),
            verdict(proxyExit, .off, expected: [proxyExit], warpCounts: false),
        ])
        #expect(decision == .rejectMatchesProtectedEgress(proxyExit))
    }

    @Test("Совпадение только с ответом-утечкой подтверждает прямой IP")
    func acceptsWhenMatchesOnlyLeak() {
        let decision = DirectIPGuard.evaluate(candidate: providerIP, verdicts: [
            verdict(cloudflare, .on),
            verdict(providerIP, .off, expected: [proxyExit], warpCounts: false),
        ])
        #expect(decision == .accept(providerIP))
    }

    @Test("warp=on у детектора, для которого warp — чужой путь, защитой не считается")
    func warpIgnoredWhenDetectorDoesNotTrustIt() {
        let decision = DirectIPGuard.evaluate(candidate: cloudflare, verdicts: [
            verdict(cloudflare, .on, warpCounts: false),
        ])
        #expect(decision == .accept(cloudflare))
    }
}
