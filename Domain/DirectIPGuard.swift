/// Guard от вырожденного случая РУ-маяка (§4.4 SPEC.md): если ответ РУ-маяка
/// совпал с protected-egress хотя бы одного детектора, значит `.ru` не в
/// сплите и запрос ушёл через VPN. Такой адрес в denylist добавлять нельзя —
/// иначе приложение само себе назначит вечную утечку.
///
/// Критерий — свойство последнего ответа маяка детектора (`warp=on` при
/// включённом флаге детектора либо адрес из его `EXPECTED_IPS`), а НЕ
/// текущее состояние машины: в Offline, Leak и Paused состояние другое, а
/// вырожденный ответ так же опасен.
enum DirectIPGuard {
    enum Decision: Hashable {
        case accept(IPAddress)
        case rejectMatchesProtectedEgress(IPAddress)
        /// Ещё ни одного вердикта маяка — принимать адрес рано: если он окажется
        /// нашим же egress, denylist отравится до первой пробы.
        case deferUntilFirstVerdict(IPAddress)
    }

    /// Последний ответ маяка одного детектора и правила, по которым тот
    /// детектор считает ответ защищённым.
    struct Verdict: Hashable {
        let trace: BeaconTrace
        let expectedIPs: Set<IPAddress>
        let warpCountsAsProtection: Bool

        init(trace: BeaconTrace, expectedIPs: Set<IPAddress>, warpCountsAsProtection: Bool = true) {
            self.trace = trace
            self.expectedIPs = expectedIPs
            self.warpCountsAsProtection = warpCountsAsProtection
        }

        var looksProtected: Bool {
            (trace.warp.indicatesWarp && warpCountsAsProtection)
                || expectedIPs.contains(trace.ip)
        }
    }

    /// `verdicts` — последние ответы всех детекторов, у которых они есть.
    /// Совпадение с ответом, который его детектор считает утечкой, кандидата
    /// не отвергает: оно подтверждает, что это и есть прямой IP.
    static func evaluate(candidate: IPAddress, verdicts: [Verdict]) -> Decision {
        guard !verdicts.isEmpty else { return .deferUntilFirstVerdict(candidate) }
        if verdicts.contains(where: { $0.looksProtected && $0.trace.ip == candidate }) {
            return .rejectMatchesProtectedEgress(candidate)
        }
        return .accept(candidate)
    }
}
