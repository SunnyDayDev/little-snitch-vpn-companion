/// Одна свежая проба детектора: сходить к его маяку и превратить ответ в
/// доменный вердикт по его правилам. Классификация целиком доменная — здесь
/// только доставка ответа.
struct EvaluateProbe: Sendable {
    let beacon: any BeaconProbing

    func run(detector: DetectorConfig, criteria: EgressCriteria, timeout: Double) async -> ProbeResult {
        switch await beacon.fetchTrace(for: detector, timeout: timeout) {
        case .body(let body):
            EgressClassifier.classifyBody(body, format: detector.beacon.format, criteria: criteria)
        case .offline(let reason):
            .offline(reason)
        }
    }
}
