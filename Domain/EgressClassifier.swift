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

/// Выполненные критерии защиты для принятой пробы.
struct ProtectionEvidence: Hashable, Sendable {
    let expectedIP: IPAddress?
    let warp: WarpStatus?
}

/// Чистая классификация: таблица §4.1 SPEC.md. Denylist сильнее всего
/// остального — совпадение с ним даёт Leak даже при `warp=on`.
enum EgressClassifier {
    /// Выполненные критерии, а не все поля ответа. Запрещённый адрес
    /// перевешивает оба признака защиты, как и при классификации.
    static func protectionEvidence(_ trace: BeaconTrace,
                                   criteria: EgressCriteria) -> ProtectionEvidence? {
        guard criteria.directRuIP != trace.ip,
              !criteria.forbiddenServers.contains(trace.ip) else { return nil }
        let ip = criteria.expectedIPs.contains(trace.ip) ? trace.ip : nil
        let warp = trace.warp.indicatesWarp && criteria.acceptsWarp ? trace.warp : nil
        guard ip != nil || warp != nil else { return nil }
        return ProtectionEvidence(expectedIP: ip, warp: warp)
    }

    static func classify(_ trace: BeaconTrace, criteria: EgressCriteria) -> ProbeResult {
        if let directRuIP = criteria.directRuIP, directRuIP == trace.ip {
            return .leakCandidate(trace, .directRuIP(trace.ip))
        }
        if criteria.forbiddenServers.contains(trace.ip) {
            return .leakCandidate(trace, .forbiddenServer(trace.ip))
        }
        // У маяка без поля `warp=` (голый IP) статус `unknown`: эта строка
        // таблицы для него не выполняется никогда.
        if protectionEvidence(trace, criteria: criteria) != nil {
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
