/// IP-адрес, сравниваемый по байтам, а не по написанию: `2a09:BAC5::1`
/// и `2a09:bac5:0:0:0:0:0:1` — один адрес. Это критично для denylist
/// `FORBIDDEN_EGRESS` и allowlist `EXPECTED_IPS`.
struct IPAddress: CustomStringConvertible, Codable {
    enum Family: Codable { case v4, v6 }

    let family: Family
    let bytes: [UInt8]
    /// Исходное написание — для UI и журнала.
    let text: String

    init?(_ raw: String) {
        let trimmed = String(raw.drop(while: \.isWhitespace).reversed()
            .drop(while: \.isWhitespace).reversed())
        guard !trimmed.isEmpty,
              !trimmed.contains("%"), !trimmed.contains("/") else { return nil }

        if let v4 = Self.parseV4(trimmed) {
            family = .v4
            bytes = v4
            text = trimmed
        } else if let v6 = Self.parseV6(trimmed) {
            family = .v6
            bytes = v6
            text = trimmed
        } else {
            return nil
        }
    }

    var description: String { text }

    private static func parseV4(_ s: some StringProtocol) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt(part), value <= 255 else { return nil }
            out.append(UInt8(value))
        }
        return out
    }

    private static func parseV6(_ s: String) -> [UInt8]? {
        guard s.contains(":") else { return nil }
        // Одиночное двоеточие по краям допустимо только как часть "::"
        if s.hasPrefix(":") && !s.hasPrefix("::") { return nil }
        if s.hasSuffix(":") && !s.hasSuffix("::") { return nil }

        var tokens = s.split(separator: ":", omittingEmptySubsequences: false)
        if tokens.count >= 2, tokens[0].isEmpty, tokens[1].isEmpty { tokens.removeFirst() }
        if tokens.count >= 2, tokens[tokens.count - 1].isEmpty,
           tokens[tokens.count - 2].isEmpty { tokens.removeLast() }

        var bytes: [UInt8] = []
        var compressionIndex: Int?
        for (index, token) in tokens.enumerated() {
            if token.isEmpty {
                guard compressionIndex == nil else { return nil }
                compressionIndex = bytes.count
                continue
            }
            if token.contains(".") {
                // Встроенный IPv4 допустим только последней группой
                guard index == tokens.count - 1, let v4 = parseV4(token) else { return nil }
                bytes.append(contentsOf: v4)
                continue
            }
            guard token.count <= 4,
                  token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let group = UInt16(token, radix: 16) else { return nil }
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(group & 0xFF))
        }

        if let compressionIndex {
            let missing = 16 - bytes.count
            guard missing > 0 else { return nil }
            bytes.insert(contentsOf: [UInt8](repeating: 0, count: missing), at: compressionIndex)
        }
        guard bytes.count == 16 else { return nil }
        return bytes
    }
}

extension IPAddress {
    /// Адрес, который может быть «прямым IP сети» в интернете. Отсекаются
    /// диапазоны, которых сервис снаружи видеть не может: их ответ означает
    /// подмену по пути (за прокси-клиентом с TUN вроде Surge сервис
    /// отвечает `127.0.0.1`, а fake-IP DNS клиента живёт в 198.18.0.0/15).
    ///
    /// v4: 0.0.0.0/8, 10/8, 100.64/10 (CGNAT), 127/8, 169.254/16, 172.16/12,
    /// 192.168/16, 198.18/15, 224/4 (multicast), 240/4 (резерв и broadcast).
    /// v6: `::`, `::1`, fe80::/10, fec0::/10, fc00::/7, ff00::/8;
    /// `::ffff:a.b.c.d` — по правилам v4.
    ///
    /// Документационные диапазоны (RFC 5737, 2001:db8::/32) намеренно не
    /// отсекаются: живой сервис их не вернёт, а примеры и тесты репозитория
    /// обязаны пользоваться только ими.
    var isGloballyRoutable: Bool {
        switch family {
        case .v4: Self.isRoutableV4(bytes)
        case .v6: Self.isRoutableV6(bytes)
        }
    }

    private static func isRoutableV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch b[0] {
        case 0, 10, 127: return false
        case 100 where b[1] & 0xC0 == 64: return false        // 100.64.0.0/10
        case 169 where b[1] == 254: return false              // 169.254.0.0/16
        case 172 where b[1] & 0xF0 == 16: return false        // 172.16.0.0/12
        case 192 where b[1] == 168: return false              // 192.168.0.0/16
        case 198 where b[1] & 0xFE == 18: return false        // 198.18.0.0/15
        case 224...255: return false                          // multicast и резерв
        default: return true
        }
    }

    private static func isRoutableV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
            return isRoutableV4(Array(b[12..<16]))           // ::ffff:a.b.c.d
        }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return false } // :: и ::1
        if b[0] == 0xFE, b[1] & 0x80 == 0x80 { return false } // fe80::/10, fec0::/10
        if b[0] & 0xFE == 0xFC { return false }               // fc00::/7
        if b[0] == 0xFF { return false }                      // ff00::/8
        return true
    }
}

extension IPAddress: Hashable {
    static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        lhs.family == rhs.family && lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(bytes)
    }
}
