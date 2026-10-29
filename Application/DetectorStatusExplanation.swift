/// Только данные, объясняющие принятое состояние. Последняя проба может
/// быть ещё неподтверждённым кандидатом и потому сюда не попадает.
enum DetectorStatusExplanation: Hashable, Sendable {
    case none
    case protected(ProtectionEvidence)
    case leak(IPAddress, LeakDiagnosis)
    case offline(OfflineCause)

    enum OfflineCause: Hashable, Sendable {
        case noNetwork, beaconUnavailable, unknown
    }
}

/// Условия конкретной пробы: переименование и группы не влияют на основание.
struct StatusExplanationContext: Hashable {
    let beacon: BeaconConfig
    let proxy: ProxyConfig
    let criteria: EgressCriteria
}
