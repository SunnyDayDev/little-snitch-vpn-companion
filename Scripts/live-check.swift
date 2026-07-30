import Foundation

// Интеграционная проверка детектора на живой машине (задача 4.5).
// Собирается вместе с доменным слоем:
//   swiftc -parse-as-library Domain/*.swift Scripts/live-check.swift -o /tmp/live-check
// Сеть трогает только на чтение: два GET по сотне байт.

@main
struct LiveCheck {
    static func main() async {
        print("=== Проверка детектора на живой машине ===\n")

        let foreign = await fetch("https://www.cloudflare.com/cdn-cgi/trace")
        let fallback = foreign == nil
            ? await fetch("https://1.1.1.1/cdn-cgi/trace")
            : nil
        guard let body = foreign ?? fallback else {
            print("✗ Оба маяка недоступны → Offline (это не утечка)")
            return
        }
        print("Маяк ответил \(foreign != nil ? "(основной)" : "(резервный)"):")
        for line in body.split(whereSeparator: \.isNewline) where
            line.hasPrefix("ip=") || line.hasPrefix("warp=")
            || line.hasPrefix("colo=") || line.hasPrefix("loc=") {
            print("  \(line)")
        }

        guard let trace = TraceParser.parse(body) else {
            print("✗ Ответ не разобран → Offline")
            return
        }

        let ruIP = await fetchDirectIP()
        if let ruIP {
            print("\nРУ-маяк: прямой IP сети = \(ruIP.text)")
        } else {
            print("\nРУ-маяк недоступен — динамическая часть denylist пуста")
        }

        var criteria = EgressCriteria()
        // Заполнители RFC 5737 — подставьте адреса своих VPN-серверов (§13 SPEC.md)
        criteria.forbiddenServers = Set([
            "198.51.100.10", "198.51.100.20", "198.51.100.21", "198.51.100.30",
        ].compactMap(IPAddress.init))
        // Guard §4.4: адрес РУ-маяка не идёт в denylist, если он равен egress
        if let ruIP, ruIP != trace.ip { criteria.directRuIP = ruIP }

        print("\nВердикт по фактическому egress:")
        report(EgressClassifier.classify(trace, criteria: criteria))

        print("\nКонтрольные подмены (debug-сценарии §14):")
        var ignoreWarp = criteria
        ignoreWarp.ignoreWarpForDebug = true
        print("  сценарий 2 (игнорировать warp=on):")
        report(EgressClassifier.classify(trace, criteria: ignoreWarp), indent: "    ")

        if let server = IPAddress("198.51.100.10") {
            let fake = BeaconTrace(ip: server, warp: .on, colo: "AMS", loc: "NL")
            print("  сценарий 13 (egress = сервер инфраструктуры, warp=on):")
            report(EgressClassifier.classify(fake, criteria: criteria), indent: "    ")
        }
        if let ruIP {
            let fake = BeaconTrace(ip: ruIP, warp: .on, colo: "AMS", loc: "NL")
            print("  сценарий 14 (egress = прямой РУ-IP):")
            report(EgressClassifier.classify(fake, criteria: criteria), indent: "    ")
        }
    }

    static func report(_ result: ProbeResult, indent: String = "  ") {
        switch result {
        case .protected(let trace):
            print("\(indent)✓ Protected — egress \(trace.ip.text) · warp=\(trace.warp.rawValue)"
                + (trace.colo.map { " · \($0)" } ?? ""))
        case .leakCandidate(let trace, let diagnosis):
            let reason = switch diagnosis {
            case .forbiddenServer(let ip): "цепочка вышла напрямую с сервера \(ip.text)"
            case .directRuIP: "полный обход VPN: трафик идёт с прямого IP сети"
            case .foreignEgress: "трафик идёт мимо VPN"
            }
            print("\(indent)⚠ Leak-кандидат — egress \(trace.ip.text): \(reason)")
        case .offline(let reason):
            print("\(indent)○ Offline (\(reason.rawValue)) — группы не трогаем")
        }
    }

    static func fetch(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func fetchDirectIP() async -> IPAddress? {
        for urlString in ["https://yandex.ru/internet/api/v0/ip", "https://2ip.ru"] {
            guard let url = URL(string: urlString) else { continue }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  var text = String(data: data, encoding: .utf8) else { continue }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
                text = String(text.dropFirst().dropLast())
            }
            if let ip = IPAddress(text) { return ip }
        }
        return nil
    }
}
