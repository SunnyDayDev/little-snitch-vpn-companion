/// Критерии, по которым ответ маяка превращается в вердикт (§4.1 SPEC.md).
struct EgressCriteria: Hashable {
    /// Allowlist: адреса, считающиеся защищёнными даже при `warp=off`.
    var expectedIPs: Set<IPAddress> = []
    /// Статическая часть `FORBIDDEN_EGRESS` — серверы инфраструктуры.
    var forbiddenServers: Set<IPAddress> = []
    /// Динамическая часть `FORBIDDEN_EGRESS` — прямой IP текущей сети от РУ-маяка.
    var directRuIP: IPAddress?
    /// Скрытый debug-режим для приёмки (сценарии 2–3 §14 SPEC.md).
    var ignoreWarpForDebug = false
}

/// Чистая классификация: таблица §4.1 SPEC.md. Denylist сильнее всего
/// остального — совпадение с ним даёт Leak даже при `warp=on`.
enum EgressClassifier {
    static func classify(_ trace: BeaconTrace, criteria: EgressCriteria) -> ProbeResult {
        if let directRuIP = criteria.directRuIP, directRuIP == trace.ip {
            return .leakCandidate(trace, .directRuIP(trace.ip))
        }
        if criteria.forbiddenServers.contains(trace.ip) {
            return .leakCandidate(trace, .forbiddenServer(trace.ip))
        }
        let warpProtects = trace.warp.indicatesWarp && !criteria.ignoreWarpForDebug
        if warpProtects || criteria.expectedIPs.contains(trace.ip) {
            return .protected(trace)
        }
        return .leakCandidate(trace, .foreignEgress)
    }

    /// Полный путь от сырого тела ответа до вердикта. Тело без `ip=` — Offline.
    static func classifyBody(_ body: String, criteria: EgressCriteria) -> ProbeResult {
        guard let trace = TraceParser.parse(body) else {
            return .offline(.unparsableResponse)
        }
        return classify(trace, criteria: criteria)
    }
}
