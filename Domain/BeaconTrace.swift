/// Состояние WARP по ответу маяка.
enum WarpStatus: String, Codable, Hashable {
    case off, on, plus, unknown

    /// `warp ∈ {on, plus}` — первое из двух условий защищённости (§4.1 SPEC.md).
    var indicatesWarp: Bool { self == .on || self == .plus }
}

/// Разобранный ответ маяка `/cdn-cgi/trace`.
struct BeaconTrace: Hashable, Codable {
    let ip: IPAddress
    let warp: WarpStatus
    let colo: String?
    let loc: String?

    init(ip: IPAddress, warp: WarpStatus, colo: String? = nil, loc: String? = nil) {
        self.ip = ip
        self.warp = warp
        self.colo = colo
        self.loc = loc
    }
}

/// Разбор plain-text ответа `key=value` по строкам. Ответ без валидного `ip=`
/// не разбирается — вызывающий трактует это как Offline (captive portal).
enum TraceParser {
    static func parse(_ body: String) -> BeaconTrace? {
        var fields: [String: String] = [:]
        for line in body.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            fields[key] = value
        }
        guard let rawIP = fields["ip"], let ip = IPAddress(rawIP) else { return nil }
        let warp = fields["warp"].flatMap(WarpStatus.init(rawValue:)) ?? .unknown
        return BeaconTrace(ip: ip, warp: warp, colo: fields["colo"], loc: fields["loc"])
    }
}
