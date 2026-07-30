/// Одна свежая проба: сходить к маяку и превратить ответ в доменный вердикт.
/// Классификация целиком доменная — здесь только доставка ответа.
struct EvaluateProbe: Sendable {
    let beacon: any BeaconProbing

    func run(criteria: EgressCriteria, timeout: Double) async -> ProbeResult {
        switch await beacon.fetchTrace(timeout: timeout) {
        case .body(let body):
            EgressClassifier.classifyBody(body, criteria: criteria)
        case .offline(let reason):
            .offline(reason)
        }
    }
}
