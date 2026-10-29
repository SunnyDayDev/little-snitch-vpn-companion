import Testing

@Suite("Основания защиты")
struct ProtectionEvidenceTests {
    private let ip = IPAddress("198.51.100.40")!

    @Test("Все сочетания критериев", arguments: [false, true],
          [WarpStatus.on, .plus, .off, .unknown])
    func criteriaTable(expected: Bool, warp: WarpStatus) {
        for enabled in [false, true] {
            for debug in [false, true] {
                let trace = BeaconTrace(ip: ip, warp: warp)
                let criteria = EgressCriteria(expectedIPs: expected ? [ip] : [],
                                              warpCountsAsProtection: enabled, ignoreWarpForDebug: debug)
                let acceptsWarp = warp.indicatesWarp && enabled && !debug
                let evidence = EgressClassifier.protectionEvidence(trace, criteria: criteria)
                #expect(evidence?.expectedIP == (expected ? ip : nil))
                #expect(evidence?.warp == (acceptsWarp ? warp : nil))
                #expect((evidence != nil) == (expected || acceptsWarp))
                if expected || acceptsWarp {
                    #expect(EgressClassifier.classify(trace, criteria: criteria) == .protected(trace))
                } else {
                    #expect(EgressClassifier.classify(trace, criteria: criteria)
                        == .leakCandidate(trace, .foreignEgress))
                }
            }
        }
    }

    @Test("Оба запрещённых источника сильнее защиты", arguments: [false, true], [false, true])
    func forbiddenTable(server: Bool, direct: Bool) {
        let trace = BeaconTrace(ip: ip, warp: .on)
        let criteria = EgressCriteria(expectedIPs: [ip], forbiddenServers: server ? [ip] : [],
                                      directRuIP: direct ? ip : nil)
        let evidence = EgressClassifier.protectionEvidence(trace, criteria: criteria)
        if direct {
            #expect(evidence == nil)
            #expect(EgressClassifier.classify(trace, criteria: criteria)
                == .leakCandidate(trace, .directRuIP(ip)))
        } else if server {
            #expect(evidence == nil)
            #expect(EgressClassifier.classify(trace, criteria: criteria)
                == .leakCandidate(trace, .forbiddenServer(ip)))
        } else {
            #expect(evidence == ProtectionEvidence(expectedIP: ip, warp: .on))
        }
    }
}
