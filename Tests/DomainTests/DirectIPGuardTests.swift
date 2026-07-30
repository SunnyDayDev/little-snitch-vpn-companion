import Testing

@Suite("Guard прямого РУ-IP")
struct DirectIPGuardTests {
    private let cloudflare = IPAddress("2a09:bac5::3f")!
    private let providerIP = IPAddress("203.0.113.40")!

    private func trace(_ ip: IPAddress, _ warp: WarpStatus) -> BeaconTrace {
        BeaconTrace(ip: ip, warp: warp)
    }

    @Test("Обычный ответ РУ-маяка принимается в denylist")
    func acceptsNormalAnswer() {
        let decision = DirectIPGuard.evaluate(candidate: providerIP,
                                              lastTrace: trace(cloudflare, .on),
                                              expectedIPs: [])
        #expect(decision == .accept(providerIP))
    }

    @Test("Совпадение с protected-egress отвергается: РУ-маяк ушёл через VPN")
    func rejectsWhenMatchesProtectedEgress() {
        let decision = DirectIPGuard.evaluate(candidate: cloudflare,
                                              lastTrace: trace(cloudflare, .on),
                                              expectedIPs: [])
        #expect(decision == .rejectMatchesProtectedEgress(cloudflare))
    }

    /// Регрессия: guard раньше смотрел на состояние машины, поэтому в Offline,
    /// Leak и Paused вырожденный ответ принимался и отравлял denylist —
    /// приложение назначало себе вечную утечку.
    @Test("Отвергает независимо от состояния — критерий в ответе маяка, а не в состоянии")
    func rejectsRegardlessOfState() {
        // warp=plus — тоже защищённый egress
        #expect(DirectIPGuard.evaluate(candidate: cloudflare,
                                       lastTrace: trace(cloudflare, .plus),
                                       expectedIPs: [])
            == .rejectMatchesProtectedEgress(cloudflare))
        // Адрес из EXPECTED_IPS при warp=off тоже считается защищённым
        #expect(DirectIPGuard.evaluate(candidate: providerIP,
                                       lastTrace: trace(providerIP, .off),
                                       expectedIPs: [providerIP])
            == .rejectMatchesProtectedEgress(providerIP))
    }

    @Test("При реальной утечке egress и есть прямой IP — адрес принимается")
    func acceptsDuringRealLeak() {
        // warp=off и адрес не из ожидаемых: это утечка, а не наш egress
        let decision = DirectIPGuard.evaluate(candidate: providerIP,
                                              lastTrace: trace(providerIP, .off),
                                              expectedIPs: [])
        #expect(decision == .accept(providerIP))
    }

    @Test("Без вердикта маяка решение откладывается")
    func defersWithoutVerdict() {
        let decision = DirectIPGuard.evaluate(candidate: providerIP,
                                              lastTrace: nil,
                                              expectedIPs: [])
        #expect(decision == .deferUntilFirstVerdict(providerIP))
    }
}
