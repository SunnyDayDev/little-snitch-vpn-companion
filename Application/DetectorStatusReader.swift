/// Проекция принятых вердиктов. Сырые trace сюда намеренно не попадают.
enum DetectorStatusReader {
    static func make(snapshot: MonitoringSnapshot, monitoring: StatusMonitoring,
                     observeOnly: Bool, capturedAt: Instant, detectorID: String?) throws -> StatusDocument {
        let all = snapshot.detectors.map { value in
            StatusDetector(id: value.id.rawValue, name: value.name, isEnabled: value.isEnabled,
                           mode: value.mode == .strict ? .strict : .reactive,
                           state: value.isEnabled ? StatusState(rawValue: value.state.rawValue)! : .disabled,
                           explanation: explanation(value),
                           lastCheck: value.isEnabled ? value.lastCheck.map { StatusDocument.timestamp($0.secondsSinceEpoch) } : nil,
                           tripwireActive: value.isEnabled && value.tripwireActive,
                           assignedGroups: value.groups)
        }
        var result = StatusDocument(
            capturedAt: StatusDocument.timestamp(capturedAt.secondsSinceEpoch), monitoring: monitoring,
            observeOnly: observeOnly, helperUnavailable: snapshot.helperUnavailable,
            groups: StatusGroups(known: snapshot.groupsStateKnown,
                                 active: snapshot.groupsStateKnown ? snapshot.activeLeakGroups : nil))
        if let detectorID {
            guard let detector = all.first(where: { $0.id == detectorID }) else {
                throw StatusFailure(code: .detectorNotFound, message: "Детектор с указанным ID не найден")
            }
            result.detector = detector
        } else {
            result.detectors = all
            result.overall = StatusOverall(state: StatusState(rawValue: snapshot.state.rawValue)!,
                                           culpritID: snapshot.overall.culprit?.rawValue,
                                           hasEnabledDetectors: snapshot.overall.hasEnabledDetectors,
                                           hasStrictClosed: snapshot.overall.hasStrictClosed)
        }
        return result
    }

    private static func explanation(_ value: DetectorSnapshot) -> StatusExplanation? {
        guard value.isEnabled else { return nil }
        switch (value.state, value.explanation) {
        case (.protected, .protected(let evidence)):
            return .protected(expectedIP: evidence.expectedIP?.text,
                              warp: evidence.warp.flatMap { StatusWarp(rawValue: $0.rawValue) })
        case (.leak, .leak(let ip, let diagnosis)):
            let kind: StatusDiagnosis = switch diagnosis {
            case .forbiddenServer: .forbiddenServer
            case .directRuIP: .directRuIP
            case .foreignEgress: .foreignEgress
            }
            return .leak(ip: ip.text, diagnosis: kind)
        case (.offline, .offline(let cause)):
            let reason: StatusOfflineCause = switch cause {
            case .noNetwork: .noNetwork
            case .beaconUnavailable: .beaconUnavailable
            case .unknown: .unknown
            }
            return .offline(reason)
        default: return nil
        }
    }
}
