import Foundation
import Network

// Интеграционная проверка детектора на живой машине (задачи 4.5 и 4.3 change
// add-multiple-detectors). Собирается вместе с доменным слоем:
//   swiftc -parse-as-library Domain/*.swift Scripts/live-check.swift -o /tmp/live-check
// Без параметров — детектор «Основной»: напрямую, маяк Cloudflare.
// Параметры детектора:
//   --socks5 хост:порт | --http-connect хост:порт   прокси пробы
//   --beacon URL                                   основной маяк
//   --fallback URL | --no-fallback                 резервный маяк
//   --plain-ip                                     формат ответа «голый IP»
//   --no-warp                                      warp=on не считается защитой
//   --expect IP[,IP…]                              ожидаемые IP детектора
// Сеть трогает только на чтение: несколько GET по сотне байт.

@main
struct LiveCheck {
    static func main() async {
        guard let options = Options(CommandLine.arguments.dropFirst()) else {
            print("Не разобраны параметры. См. шапку Scripts/live-check.swift.")
            exit(2)
        }
        print("=== Проверка детектора на живой машине ===\n")
        print("Путь: \(options.proxyDescription)")
        print("Маяк: \(options.beacon.primaryURL) (\(options.beacon.format.rawValue))"
            + (options.beacon.fallbackURL.map { ", резервный \($0)" } ?? ""))
        print("")

        let primary = await fetch(options.beacon.primaryURL, proxy: options.proxy)
        let fallback: String?
        if primary == nil, let fallbackURL = options.beacon.fallbackURL {
            fallback = await fetch(fallbackURL, proxy: options.proxy)
        } else {
            fallback = nil
        }
        guard let body = primary ?? fallback else {
            print("✗ Маяк недоступен\(options.proxy.isDirect ? "" : " через прокси") → Offline (это не утечка)")
            return
        }
        print("Маяк ответил \(primary != nil ? "(основной)" : "(резервный)"):")
        for line in body.split(whereSeparator: \.isNewline).prefix(12) where
            options.beacon.format == .plainIP
            || line.hasPrefix("ip=") || line.hasPrefix("warp=")
            || line.hasPrefix("colo=") || line.hasPrefix("loc=") {
            print("  \(line)")
        }

        guard let trace = BeaconResponseParser.parse(body, format: options.beacon.format) else {
            print("✗ Ответ не разобран → Offline")
            return
        }

        // РУ-маяк всегда напрямую: прямой IP один на машину.
        let ruIP = await fetchDirectIP()
        if let ruIP {
            print("\nРУ-маяк: прямой IP сети = \(ruIP.text)")
        } else {
            print("\nРУ-маяк недоступен — динамическая часть denylist пуста")
        }
        if !options.proxy.isDirect {
            print(ruIP == trace.ip
                ? "⚠ egress через прокси совпал с прямым IP сети: прокси не туннелирует"
                : "✓ egress через прокси отличается от прямого IP сети: проба ушла через прокси")
        }

        var detector = DetectorConfig.primary()
        detector.beacon = options.beacon
        detector.proxy = options.proxy
        detector.warpCountsAsProtection = options.warpCountsAsProtection
        detector.expectedIPs = options.expectedIPs
        // Заполнители RFC 5737 — подставьте адреса своих VPN-серверов (§13 SPEC.md)
        detector.forbiddenEgressIPs = ["198.51.100.10", "198.51.100.20", "198.51.100.21", "198.51.100.30"]
        // Guard §4.4: адрес РУ-маяка не идёт в denylist, если он равен egress
        let directRuIP = ruIP.flatMap { $0 != trace.ip ? $0 : nil }
        let criteria = detector.criteria(directRuIP: directRuIP)

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
            var withDirect = criteria
            withDirect.directRuIP = ruIP
            print("  сценарий 14 (egress = прямой РУ-IP):")
            report(EgressClassifier.classify(fake, criteria: withDirect), indent: "    ")
        }
    }

    struct Options {
        var proxy = ProxyConfig.direct
        var beacon = BeaconConfig.cloudflare
        var warpCountsAsProtection = true
        var expectedIPs: [String] = []

        init?(_ arguments: ArraySlice<String>) {
            var rest = arguments
            while let flag = rest.popFirst() {
                switch flag {
                case "--socks5", "--http-connect":
                    guard let raw = rest.popFirst(),
                          let address = ProxyConfig.parseAddress(raw) else { return nil }
                    proxy = ProxyConfig(kind: flag == "--socks5" ? .socks5 : .httpConnect,
                                        host: address.host, port: address.port)
                case "--beacon":
                    guard let url = rest.popFirst(), BeaconConfig.isValidURL(url) else { return nil }
                    beacon.primaryURL = url
                case "--fallback":
                    guard let url = rest.popFirst(), BeaconConfig.isValidURL(url) else { return nil }
                    beacon.fallbackURL = url
                case "--no-fallback":
                    beacon.fallbackURL = nil
                case "--plain-ip":
                    beacon.format = .plainIP
                case "--no-warp":
                    warpCountsAsProtection = false
                case "--expect":
                    guard let list = rest.popFirst() else { return nil }
                    expectedIPs = list.split(separator: ",").map(String.init)
                default:
                    return nil
                }
            }
        }

        var proxyDescription: String {
            switch proxy.kind {
            case .direct: "напрямую (системный прокси не используется)"
            case .httpConnect: "HTTP CONNECT \(proxy.address)"
            case .socks5: "SOCKS5 \(proxy.address)"
            }
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
            case .foreignEgress: "трафик идёт мимо ожидаемого пути"
            }
            print("\(indent)⚠ Leak-кандидат — egress \(trace.ip.text): \(reason)")
        case .offline(let reason):
            print("\(indent)○ Offline (\(reason.rawValue)) — группы не трогаем")
        }
    }

    /// Та же сборка сессии, что у `BeaconProber`: прокси без отката на прямой
    /// путь, без прокси — с выключенным системным.
    static func fetch(_ urlString: String, proxy: ProxyConfig) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        if !proxy.isDirect, let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            var proxyConfiguration = proxy.kind == .socks5
                ? ProxyConfiguration(socksv5Proxy: endpoint)
                : ProxyConfiguration(httpCONNECTProxy: endpoint)
            proxyConfiguration.allowFailover = false
            configuration.proxyConfigurations = [proxyConfiguration]
        } else {
            configuration.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            print("  (\(urlString): \((error as NSError).domain) \((error as NSError).code))")
            return nil
        }
    }

    /// Как `RuBeaconProber`: напрямую, мимо системного прокси, и только
    /// глобально маршрутизируемый ответ — `127.0.0.1` от локального прокси
    /// отбрасывается с пометкой.
    static func fetchDirectIP() async -> IPAddress? {
        for urlString in ["https://yandex.ru/internet/api/v0/ip", "https://ip.beget.ru"] {
            guard let url = URL(string: urlString) else { continue }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 6
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: url)
            request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            guard let ip = PlainIPParser.parse(text) else { continue }
            guard ip.isGloballyRoutable else {
                print("РУ-маяк \(urlString) вернул немаршрутизируемый адрес \(ip.text) — ответ отброшен")
                continue
            }
            return ip
        }
        return nil
    }
}
