/// Критерии, по которым ответ маяка превращается в вердикт (§4.1 SPEC.md).
/// Свои у каждого детектора: правила одного не влияют на пробы другого.
struct EgressCriteria: Hashable {
    /// Allowlist: адреса, считающиеся защищёнными даже при `warp=off`.
    var expectedIPs: Set<IPAddress> = []
    /// Статическая часть `FORBIDDEN_EGRESS` — серверы инфраструктуры.
    var forbiddenServers: Set<IPAddress> = []
    /// Динамическая часть `FORBIDDEN_EGRESS` — прямой IP текущей сети от
    /// РУ-маяка, общий для всех детекторов.
    var directRuIP: IPAddress?
    /// «`warp=on` считается защитой» — флаг детектора (D3 design.md).
    var warpCountsAsProtection = true
    /// Скрытый debug-режим для приёмки (сценарии 2–3 §14 SPEC.md). Глобальный:
    /// накладывается на флаг детектора через И.
    var ignoreWarpForDebug = false

    /// `warp=on/plus` даёт защиту только при включённом флаге и снятом
    /// debug-рычаге.
    var acceptsWarp: Bool { warpCountsAsProtection && !ignoreWarpForDebug }
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
        // У маяка без поля `warp=` (голый IP) статус `unknown`: эта строка
        // таблицы для него не выполняется никогда.
        let warpProtects = trace.warp.indicatesWarp && criteria.acceptsWarp
        if warpProtects || criteria.expectedIPs.contains(trace.ip) {
            return .protected(trace)
        }
        return .leakCandidate(trace, .foreignEgress)
    }

    /// Полный путь от сырого тела ответа до вердикта. Тело без адреса — Offline.
    static func classifyBody(_ body: String,
                             format: BeaconFormat = .cdnCgiTrace,
                             criteria: EgressCriteria) -> ProbeResult {
        guard let trace = BeaconResponseParser.parse(body, format: format) else {
            return .offline(.unparsableResponse)
        }
        return classify(trace, criteria: criteria)
    }
}
