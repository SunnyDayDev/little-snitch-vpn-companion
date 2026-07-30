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

extension IPAddress: Hashable {
    static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        lhs.family == rhs.family && lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(family)
        hasher.combine(bytes)
    }
}
