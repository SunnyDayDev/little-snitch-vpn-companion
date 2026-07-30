/// Guard от вырожденного случая РУ-маяка (§4.4 SPEC.md): если ответ РУ-маяка
/// совпал с текущим protected-egress, значит `.ru` не в сплите и запрос ушёл
/// через VPN. Такой адрес в denylist добавлять нельзя — иначе приложение
/// само себе назначит вечную утечку.
///
/// Критерий — свойство последнего ответа foreign-маяка (`warp=on` либо адрес из
/// `EXPECTED_IPS`), а НЕ текущее состояние машины: в Offline, Leak и Paused
/// состояние другое, а вырожденный ответ так же опасен.
enum DirectIPGuard {
    enum Decision: Hashable {
        case accept(IPAddress)
        case rejectMatchesProtectedEgress(IPAddress)
        /// Ещё ни одного вердикта маяка — принимать адрес рано: если он окажется
        /// нашим же egress, denylist отравится до первой пробы.
        case deferUntilFirstVerdict(IPAddress)
    }

    static func evaluate(candidate: IPAddress,
                         lastTrace: BeaconTrace?,
                         expectedIPs: Set<IPAddress>) -> Decision {
        guard let lastTrace else { return .deferUntilFirstVerdict(candidate) }
        let traceLooksProtected = lastTrace.warp.indicatesWarp
            || expectedIPs.contains(lastTrace.ip)
        if traceLooksProtected, lastTrace.ip == candidate {
            return .rejectMatchesProtectedEgress(candidate)
        }
        return .accept(candidate)
    }
}
