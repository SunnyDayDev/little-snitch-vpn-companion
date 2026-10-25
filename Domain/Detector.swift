/// Идентификатор детектора. Имя детектора уникальным быть не обязано —
/// различаются детекторы только по нему. Domain не знает о `UUID`
/// (Foundation), поэтому это строка: новые значения генерирует слой выше.
struct DetectorID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    /// Детектор «Основной»: дефолт чистой установки и итог миграции настроек
    /// одного детектора. Постоянный идентификатор нужен, чтобы детектор,
    /// собранный в памяти до записи в defaults, совпадал с записанным.
    static let primary = DetectorID("00000000-0000-4000-8000-000000000001")
}

/// Формат ответа маяка (§4.1 SPEC.md).
enum BeaconFormat: String, Codable, Hashable, CaseIterable, Sendable {
    /// Plain text `key=value` по строкам: значимы `ip=` и `warp=`. Отдаёт
    /// любой домен за Cloudflare.
    case cdnCgiTrace
    /// Тело — IP-адрес, допустима JSON-строка `"<ip>"`. Поля `warp=` нет:
    /// защиту определяют только ожидаемые адреса.
    case plainIP
}

/// Маяк детектора: основной URL, необязательный резервный и формат ответа.
struct BeaconConfig: Hashable, Codable, Sendable {
    var primaryURL: String
    /// `nil` — резервного маяка нет: недоступность основного даёт Offline.
    var fallbackURL: String?
    var format: BeaconFormat

    init(primaryURL: String, fallbackURL: String?, format: BeaconFormat) {
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.format = format
    }

    /// Прежняя пара маяков приложения: резервный — по IP, без DNS.
    static let cloudflare = BeaconConfig(
        primaryURL: "https://www.cloudflare.com/cdn-cgi/trace",
        fallbackURL: "https://1.1.1.1/cdn-cgi/trace",
        format: .cdnCgiTrace)

    /// Нераспознанный формат — `cdn-cgi/trace`: так вёл себя единственный
    /// маяк до появления детекторов.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryURL = try container.decodeIfPresent(String.self, forKey: .primaryURL)
            ?? Self.cloudflare.primaryURL
        fallbackURL = try container.decodeIfPresent(String.self, forKey: .fallbackURL)
        format = try container.decodeIfPresent(String.self, forKey: .format)
            .flatMap(BeaconFormat.init(rawValue:)) ?? .cdnCgiTrace
    }

    /// Строка похожа на URL маяка: схема `http(s)` и непустой хост без
    /// пробелов. Полный разбор URL — забота инфраструктуры; здесь — отсев
    /// того, что заведомо не адрес.
    static func isValidURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        let rest: Substring
        if lowered.hasPrefix("https://") {
            rest = raw.dropFirst("https://".count)
        } else if lowered.hasPrefix("http://") {
            rest = raw.dropFirst("http://".count)
        } else {
            return false
        }
        guard !raw.contains(where: \.isWhitespace) else { return false }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = authority.split(separator: "@").last.map(String.init) ?? ""
        return !host.isEmpty && host != ":"
    }
}

/// Прокси детектора (D5 design.md): проба и растяжка ходят через него.
/// Аутентификации в этой версии нет. Адрес хранится и у детектора без
/// прокси — переключение сегмента «Нет» и обратно не теряет его.
struct ProxyConfig: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
        /// Без прокси: напрямую, системные настройки прокси не используются.
        case direct = "none"
        case httpConnect
        case socks5
    }

    var kind: Kind
    var host: String
    var port: Int

    init(kind: Kind = .direct, host: String = "", port: Int = 0) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    static let direct = ProxyConfig()

    var isDirect: Bool { kind == .direct }

    /// `хост:порт`; IPv6-хост — в квадратных скобках.
    var address: String {
        guard !host.isEmpty else { return "" }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return port > 0 ? "\(shownHost):\(port)" : shownHost
    }

    /// Нераспознанный вид прокси — без прокси: так вёл себя единственный
    /// детектор до появления прокси.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
            .flatMap(Kind.init(rawValue:)) ?? .direct
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 0
    }

    /// Разбор поля «Адрес прокси»: `хост:порт` или `[ipv6]:порт`, порт
    /// 1–65535. Строка без порта — не адрес: подставлять порт молча нельзя.
    static func parseAddress(_ raw: String) -> (host: String, port: Int)? {
        let text = String(raw.drop(while: \.isWhitespace).reversed()
            .drop(while: \.isWhitespace).reversed())
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        let host: String
        let portText: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let afterBracket = text[text.index(after: close)...]
            guard afterBracket.hasPrefix(":") else { return nil }
            portText = afterBracket.dropFirst()
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = String(text[..<colon])
            // Голый IPv6 без скобок неотличим от «хост:порт» — требуем скобки.
            guard !host.contains(":") else { return nil }
            portText = text[text.index(after: colon)...]
        }
        guard !host.isEmpty,
              !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (1...65_535).contains(port) else { return nil }
        return (host, port)
    }
}

/// Детектор (D3–D6 design.md): единица наблюдения со своими маяком, путём,
/// правилами классификации, режимом защиты и группами. Конфигурация живёт
/// в Domain, рантайм (машина, растяжка, пробы) — в Application.
struct DetectorConfig: Hashable, Codable, Sendable, Identifiable {
    var id: DetectorID
    var name: String
    var isEnabled: Bool
    var protectionMode: ProtectionMode
    var beacon: BeaconConfig
    var proxy: ProxyConfig
    /// «`warp=on` считается защитой». Для пути через резидентный прокси
    /// `warp=on` означает чужой путь, а не защиту.
    var warpCountsAsProtection: Bool
    /// Allowlist `EXPECTED_IPS` детектора.
    var expectedIPs: [String]
    /// Статическая часть `FORBIDDEN_EGRESS` детектора; прямой IP сети
    /// подставляется к ней общий для всех.
    var forbiddenEgressIPs: [String]
    /// Растяжка опциональна: через прокси её обрыв описывает прокси, а не
    /// туннель, и пользователь может предпочесть только пробы.
    var tripwireEnabled: Bool
    /// Маппинг детектора: группы, которые он включает (§5 SPEC.md).
    var groups: [String]

    init(id: DetectorID,
         name: String,
         isEnabled: Bool = true,
         protectionMode: ProtectionMode = .reactive,
         beacon: BeaconConfig = .cloudflare,
         proxy: ProxyConfig = .direct,
         warpCountsAsProtection: Bool = true,
         expectedIPs: [String] = [],
         forbiddenEgressIPs: [String] = [],
         tripwireEnabled: Bool = true,
         groups: [String] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.protectionMode = protectionMode
        self.beacon = beacon
        self.proxy = proxy
        self.warpCountsAsProtection = warpCountsAsProtection
        self.expectedIPs = expectedIPs
        self.forbiddenEgressIPs = forbiddenEgressIPs
        self.tripwireEnabled = tripwireEnabled
        self.groups = groups
    }

    static let primaryName = "Основной"
    static let newDetectorName = "Новый детектор"

    /// Детектор «Основной» по умолчанию (§13 SPEC.md). Группы пусты: имя
    /// «VPN down» подставляется один раз, только если группа есть в LS.
    static func primary() -> DetectorConfig {
        DetectorConfig(id: .primary, name: primaryName)
    }

    /// Детектор, добавленный пользователем: дефолты «Основного», кроме имени
    /// и групп.
    static func newDetector(id: DetectorID) -> DetectorConfig {
        DetectorConfig(id: id, name: newDetectorName)
    }

    /// Выключенная копия «<имя> (копия)»: включать её — решение пользователя,
    /// иначе дубль сразу начал бы ходить в сеть и трогать группы.
    func duplicated(id: DetectorID) -> DetectorConfig {
        var copy = self
        copy.id = id
        copy.name = "\(name) (копия)"
        copy.isEnabled = false
        return copy
    }

    var mapping: RuleGroupMapping { RuleGroupMapping(leakGroups: groups) }

    /// Критерии классификации детектора. Прямой IP сети один на машину и
    /// подставляется во все детекторы одинаково; debug-рычаг глобальный и
    /// накладывается на флаг детектора через И.
    func criteria(directRuIP: IPAddress?, ignoreWarpForDebug: Bool = false) -> EgressCriteria {
        EgressCriteria(
            expectedIPs: Set(expectedIPs.compactMap(IPAddress.init)),
            forbiddenServers: Set(forbiddenEgressIPs.compactMap(IPAddress.init)),
            directRuIP: directRuIP,
            warpCountsAsProtection: warpCountsAsProtection,
            ignoreWarpForDebug: ignoreWarpForDebug)
    }

    /// Нераспознанное значение режима — реактивный (безопасный дефолт, как и
    /// у прежнего ключа `protectionMode`); отсутствующие поля — дефолты
    /// нового детектора: запись от будущей версии не должна ломать чтение.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DetectorConfig(id: .primary, name: Self.newDetectorName)
        id = try container.decode(DetectorID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? fallback.isEnabled
        protectionMode = try container.decodeIfPresent(String.self, forKey: .protectionMode)
            .flatMap(ProtectionMode.init(rawValue:)) ?? .reactive
        beacon = try container.decodeIfPresent(BeaconConfig.self, forKey: .beacon)
            ?? fallback.beacon
        proxy = try container.decodeIfPresent(ProxyConfig.self, forKey: .proxy)
            ?? fallback.proxy
        warpCountsAsProtection = try container.decodeIfPresent(
            Bool.self, forKey: .warpCountsAsProtection) ?? fallback.warpCountsAsProtection
        expectedIPs = try container.decodeIfPresent([String].self, forKey: .expectedIPs) ?? []
        forbiddenEgressIPs = try container.decodeIfPresent(
            [String].self, forKey: .forbiddenEgressIPs) ?? []
        tripwireEnabled = try container.decodeIfPresent(Bool.self, forKey: .tripwireEnabled)
            ?? fallback.tripwireEnabled
        groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
    }
}
