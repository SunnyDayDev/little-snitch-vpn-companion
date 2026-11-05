import Foundation
import Testing

@Suite("CLI статуса и JSON-контракт")
struct StatusCommandTests {
    static func document(selected: Bool = false) -> StatusDocument {
        let detector = StatusDetector(id: "detector-a", name: "Основной", isEnabled: true, mode: .strict,
                                      state: .leak, explanation: .leak(ip: "203.0.113.5", diagnosis: .foreignEgress),
                                      lastCheck: nil, tripwireActive: false, assignedGroups: ["VPN down"])
        return StatusDocument(capturedAt: StatusDocument.timestamp(100), monitoring: .running,
                              observeOnly: false, helperUnavailable: false,
                              groups: StatusGroups(known: false, active: nil),
                              overall: selected ? nil : StatusOverall(state: .leak, culpritID: detector.id,
                                  hasEnabledDetectors: true, hasStrictClosed: false),
                              detectors: selected ? nil : [detector], detector: selected ? detector : nil)
    }

    @Test("Все сочетания флагов и порядок", arguments: [
        ["status"], ["status", "--json"], ["status", "--detector", "detector-a"],
        ["status", "--detector", "detector-a", "--json"], ["status", "--json", "--detector", "detector-a"]])
    func combinations(_ args: [String]) throws {
        let value = try StatusCommand.parse(args)
        #expect(value.json == args.contains("--json"))
        #expect((value.detectorID != nil) == args.contains("--detector"))
        let result = StatusCommand.execute(args) { Self.document(selected: $0 != nil) }
        #expect(result.code == 0)
        #expect(result.stderr.isEmpty)
        if value.json {
            let json = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            #expect((json["detector"] != nil) == (value.detectorID != nil))
            #expect((json["detectors"] != nil) == (value.detectorID == nil))
        } else { #expect(result.stdout.contains("detector-a")) }
    }

    @Test("Ошибки синтаксиса до подключения", arguments: [
        [], ["check"], ["status", "--other"], ["status", "--json", "--json"],
        ["status", "--detector"], ["status", "--detector", ""], ["status", "--detector", "   "],
        ["status", "--detector", "--json"], ["status", "a"],
        ["status", "--detector", "a", "--detector", "b"], ["status", "--help", "--json"]])
    func syntax(_ args: [String]) {
        let result = StatusCommand.execute(args) { _ in Issue.record("Клиент не должен вызываться"); return Self.document() }
        #expect(result.code == 2)
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }

    @Test("Справка без сервера", arguments: [["--help"], ["status", "--help"]])
    func help(_ args: [String]) {
        let result = StatusCommand.execute(args) { _ in throw StatusFailure.unavailable }
        #expect(result.code == 0)
        #expect(result.stdout.contains("--detector"))
    }

    @Test("Ошибки только в stderr", arguments: [StatusExitCode.failure, .usage, .unavailable, .detectorNotFound, .incompatible])
    func errors(_ code: StatusExitCode) {
        let result = StatusCommand.execute(["status", "--json"]) { _ in throw StatusFailure(code: code, message: "Ошибка") }
        #expect(result.code == code.rawValue)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == "Ошибка\n")
    }

    @Test("Обязательные null и отсутствие альтернативной формы")
    func nullsAndShapes() throws {
        let doc = Self.document(selected: true)
        let data = try JSONEncoder().encode(doc)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let detector = try #require(root["detector"] as? [String: Any])
        #expect(detector["lastCheck"] is NSNull)
        #expect(root["overall"] == nil)
        let decoded = try JSONDecoder().decode(StatusDocument.self, from: data)
        try decoded.validate(detectorID: "detector-a")
        var bad = root
        var badDetector = detector
        badDetector.removeValue(forKey: "lastCheck")
        bad["detector"] = badDetector
        #expect(throws: (any Error).self) { try JSONDecoder().decode(StatusDocument.self, from: JSONSerialization.data(withJSONObject: bad)) }
        var incompatible = doc
        incompatible.schemaVersion = 2
        #expect(throws: StatusFailure.self) { try incompatible.validate(detectorID: "detector-a") }
    }

    @Test("Все основания имеют явный стабильный формат", arguments: [
        StatusExplanation.protected(expectedIP: nil, warp: .on), .protected(expectedIP: "198.51.100.40", warp: nil),
        .protected(expectedIP: "198.51.100.40", warp: .plus),
        .leak(ip: "203.0.113.5", diagnosis: .forbiddenServer), .leak(ip: "203.0.113.5", diagnosis: .directRuIP),
        .leak(ip: "203.0.113.5", diagnosis: .foreignEgress),
        .offline(.noNetwork), .offline(.beaconUnavailable), .offline(.unknown)])
    func explanations(_ value: StatusExplanation) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(StatusExplanation.self, from: encoded)
        #expect(try JSONEncoder().encode(decoded).count == encoded.count)
        let root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(root["kind"] is String)
    }

    @Test("Пустой список, неизвестные группы и управляющие символы")
    func text() {
        var empty = Self.document()
        empty.detectors = []
        let output = StatusText.render(empty)
        #expect(output.contains("Детекторов нет"))
        #expect(output.contains("состояние групп неизвестно"))
        #expect(!StatusText.safe("имя\u{1b}[31m\n").contains("\u{1b}"))
        #expect(StatusText.safe("имя\n").contains("\\u{A}"))
    }
}
