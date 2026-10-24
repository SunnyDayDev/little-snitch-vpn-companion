import Foundation

// Проверка растяжки и монитора пути на живой машине (задача 4.3/4.4 исходного
// change; задача 4.3 change add-multiple-detectors — растяжка через прокси).
//   swiftc -swift-version 6 Domain/*.swift Application/Ports.swift \
//     Application/AppSettings.swift Helper/FailsafeConfig.swift \
//     Infrastructure/ProxyRouting.swift Infrastructure/TripwireConnection.swift \
//     Infrastructure/SystemPathMonitor.swift Scripts/live-tripwire.swift -o /tmp/live-tripwire
// Параметры: --socks5 хост:порт | --http-connect хост:порт — растяжка через
// прокси; --beacon URL — хост и путь heartbeat (по умолчанию маяк Cloudflare).

@main
struct LiveTripwire {
    static func main() async {
        let seconds = 14.0
        let heartbeat = 3.0
        var proxy = ProxyConfig.direct
        var beaconURL = BeaconConfig.cloudflare.primaryURL
        var arguments = CommandLine.arguments.dropFirst()
        while let flag = arguments.popFirst() {
            switch flag {
            case "--socks5", "--http-connect":
                guard let raw = arguments.popFirst(),
                      let address = ProxyConfig.parseAddress(raw) else { return usage() }
                proxy = ProxyConfig(kind: flag == "--socks5" ? .socks5 : .httpConnect,
                                    host: address.host, port: address.port)
            case "--beacon":
                guard let url = arguments.popFirst() else { return usage() }
                beaconURL = url
            default:
                return usage()
            }
        }
        guard let target = TripwireTarget(beaconURL: beaconURL) else { return usage() }
        let route = proxy.isDirect ? "напрямую" : "через \(proxy.kind.rawValue) \(proxy.address)"
        print("=== Растяжка к \(target.hostHeader)\(target.path) \(route): "
            + "heartbeat \(Int(heartbeat)) с, наблюдаем \(Int(seconds)) с ===")

        let breaks = BreakCounter()
        let tripwire = TripwireConnection()
        await tripwire.start(target: target, proxy: proxy, heartbeatSeconds: heartbeat) {
            Task { await breaks.record() }
        }

        let path = SystemPathMonitor()
        await path.start { info in
            Task { await breaks.recordPath(info) }
        }

        try? await Task.sleep(for: .seconds(seconds))
        await tripwire.stop()
        await path.stop()

        let count = await breaks.count
        let paths = await breaks.paths
        print("Обрывов растяжки за \(Int(seconds)) с: \(count)")
        print("Событий сетевого пути: \(paths.count)")
        for info in paths.prefix(3) {
            print("  путь: \(info.interfaceDescription), шлюз \(info.gateway ?? "—"), "
                + "доступен: \(info.isSatisfied)")
        }
        print(count == 0
            ? "✓ Соединение держится, heartbeat проходит — edge не рвёт его по idle"
            : "⚠ Были обрывы: \(count) — проверить дедлайн чтения, backoff и прокси")
    }

    static func usage() {
        print("Не разобраны параметры. См. шапку Scripts/live-tripwire.swift.")
    }
}

actor BreakCounter {
    private(set) var count = 0
    private(set) var paths: [NetworkPathInfo] = []

    func record() {
        count += 1
        print("  обрыв растяжки #\(count)")
    }

    func recordPath(_ info: NetworkPathInfo) {
        paths.append(info)
    }
}
