import Foundation

/// Обязательное поле JSON: отсутствие значения кодируется явным null.
@propertyWrapper
struct StatusNullable<Value: Codable & Sendable>: Codable, Sendable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        wrappedValue = value.decodeNil() ? nil : try value.decode(Value.self)
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        if let wrappedValue { try value.encode(wrappedValue) } else { try value.encodeNil() }
    }
}

enum StatusMonitoring: String, Codable, Sendable { case running, paused, stopped }
enum StatusMode: String, Codable, Sendable { case reactive, strict }
enum StatusState: String, Codable, CaseIterable, Sendable {
    case protected, leak, offline, checking, paused, disabled
}
enum StatusWarp: String, Codable, Sendable { case on, plus }
enum StatusDiagnosis: String, Codable, Sendable { case forbiddenServer, directRuIP, foreignEgress }
enum StatusOfflineCause: String, Codable, Sendable { case noNetwork, beaconUnavailable, unknown }

enum StatusExplanation: Codable, Sendable {
    case protected(expectedIP: String?, warp: StatusWarp?)
    case leak(ip: String, diagnosis: StatusDiagnosis)
    case offline(StatusOfflineCause)

    private enum Keys: String, CodingKey { case kind, expectedIP, warp, ip, diagnosis, cause }
    private enum Kind: String, Codable { case protected, leak, offline }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .protected:
            self = .protected(expectedIP: try c.decode(StatusNullable<String>.self, forKey: .expectedIP).wrappedValue,
                              warp: try c.decode(StatusNullable<StatusWarp>.self, forKey: .warp).wrappedValue)
        case .leak:
            self = .leak(ip: try c.decode(String.self, forKey: .ip),
                         diagnosis: try c.decode(StatusDiagnosis.self, forKey: .diagnosis))
        case .offline: self = .offline(try c.decode(StatusOfflineCause.self, forKey: .cause))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .protected(let ip, let warp):
            try c.encode(Kind.protected, forKey: .kind)
            try c.encode(StatusNullable(wrappedValue: ip), forKey: .expectedIP)
            try c.encode(StatusNullable(wrappedValue: warp), forKey: .warp)
        case .leak(let ip, let diagnosis):
            try c.encode(Kind.leak, forKey: .kind)
            try c.encode(ip, forKey: .ip)
            try c.encode(diagnosis, forKey: .diagnosis)
        case .offline(let cause):
            try c.encode(Kind.offline, forKey: .kind)
            try c.encode(cause, forKey: .cause)
        }
    }
}

struct StatusDetector: Codable, Sendable {
    let id: String
    let name: String
    let isEnabled: Bool
    let mode: StatusMode
    let state: StatusState
    @StatusNullable var explanation: StatusExplanation?
    @StatusNullable var lastCheck: String?
    let tripwireActive: Bool
    let assignedGroups: [String]
}

struct StatusGroups: Codable, Sendable {
    let known: Bool
    @StatusNullable var active: [String]?
}

struct StatusOverall: Codable, Sendable {
    let state: StatusState
    @StatusNullable var culpritID: String?
    let hasEnabledDetectors: Bool
    let hasStrictClosed: Bool
}

/// Две формы результата: сводка с массивом либо один выбранный детектор.
struct StatusDocument: Codable, Sendable {
    var schemaVersion = 1
    let capturedAt: String
    let monitoring: StatusMonitoring
    let observeOnly: Bool
    let helperUnavailable: Bool
    let groups: StatusGroups
    var overall: StatusOverall?
    var detectors: [StatusDetector]?
    var detector: StatusDetector?

    func validate(detectorID: String?) throws {
        guard schemaVersion == 1, Self.date(capturedAt) != nil,
              groups.known == (groups.active != nil) else { throw StatusFailure.protocolError }
        let members: [StatusDetector]
        if let detectorID {
            guard let detector, detector.id == detectorID, detectors == nil, overall == nil else {
                throw StatusFailure.protocolError
            }
            members = [detector]
        } else {
            guard let detectors, let overall, detector == nil, overall.state != .disabled else {
                throw StatusFailure.protocolError
            }
            members = detectors
        }
        guard Set(members.map(\.id)).count == members.count else { throw StatusFailure.protocolError }
        for member in members {
            guard !member.id.isEmpty, member.isEnabled == (member.state != .disabled),
                  member.lastCheck == nil || Self.date(member.lastCheck!) != nil else {
                throw StatusFailure.protocolError
            }
            if !member.isEnabled && (member.lastCheck != nil || member.tripwireActive) {
                throw StatusFailure.protocolError
            }
            switch (member.state, member.explanation) {
            case (_, nil): break
            case (.protected, .protected(let ip, let warp)):
                guard ip != nil || warp != nil else { throw StatusFailure.protocolError }
            case (.leak, .leak), (.offline, .offline): break
            default: throw StatusFailure.protocolError
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        formatter().string(from: Date(timeIntervalSince1970: seconds))
    }
    static func date(_ text: String) -> Date? { formatter().date(from: text) }
    private static func formatter() -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value.timeZone = TimeZone(secondsFromGMT: 0)
        return value
    }
}

enum StatusExitCode: Int32, Codable, Sendable {
    case failure = 1, usage = 2, unavailable = 3, detectorNotFound = 4, incompatible = 5
}

struct StatusFailure: Error, Codable, Sendable {
    let code: StatusExitCode
    let message: String
    static let protocolError = StatusFailure(code: .incompatible, message: "Несовместимый или некорректный ответ приложения")
    static let unavailable = StatusFailure(code: .unavailable, message: "Приложение недоступно: запустите Little Snitch VPN Companion")
    static let timeout = StatusFailure(code: .unavailable, message: "Приложение не ответило за отведённое время")
}

struct StatusRequest: Codable, Sendable {
    var schemaVersion = 1
    var command = "status"
    @StatusNullable var detectorID: String?
}

struct StatusResponse: Codable, Sendable {
    var schemaVersion = 1
    @StatusNullable var result: StatusDocument?
    @StatusNullable var error: StatusFailure?

    func document(detectorID: String?) throws -> StatusDocument {
        guard schemaVersion == 1, (result == nil) != (error == nil) else { throw StatusFailure.protocolError }
        if let error { throw error }
        let document = result!
        try document.validate(detectorID: detectorID)
        return document
    }
}
