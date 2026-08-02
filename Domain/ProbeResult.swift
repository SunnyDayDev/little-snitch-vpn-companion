/// Что именно спровоцировало пробу — идёт в журнал и в инфо-строку «Проверка».
enum ProbeTrigger: String, Codable, Hashable, CaseIterable {
    case startup
    case tripwire
    case path
    case scheduled
    case confirmation
    case ruBeacon
    case user
    /// События системного питания: засыпание и пробуждение (§4.2, слой 4).
    case power
}

/// Почему проба не дала ответа. Ни один из вариантов не является утечкой.
enum OfflineReason: String, Codable, Hashable {
    case timeout
    case networkFailure
    case tlsFailure
    /// HTTP 200, но тело без `ip=` — типично для captive portal.
    case unparsableResponse
}

/// Источник вердикта «утечка» — определяет формулировку в журнале и уведомлении.
enum LeakDiagnosis: Hashable, Codable {
    /// Egress совпал с сервером инфраструктуры: на выходном узле отвалился WARP.
    case forbiddenServer(IPAddress)
    /// Egress совпал с прямым РУ-IP: полный обход VPN.
    case directRuIP(IPAddress)
    /// warp=off и адрес не из ожидаемых.
    case foreignEgress
}

enum ProbeResult: Hashable, Codable {
    case protected(BeaconTrace)
    case leakCandidate(BeaconTrace, LeakDiagnosis)
    case offline(OfflineReason)

    var trace: BeaconTrace? {
        switch self {
        case .protected(let trace), .leakCandidate(let trace, _): trace
        case .offline: nil
        }
    }
}
