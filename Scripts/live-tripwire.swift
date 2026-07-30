import Foundation

// Проверка растяжки и монитора пути на живой машине (задача 4.3/4.4).
//   swiftc -swift-version 6 Domain/*.swift Application/Ports.swift \
//     Application/AppSettings.swift Infrastructure/TripwireConnection.swift \
//     Infrastructure/SystemPathMonitor.swift Scripts/live-tripwire.swift -o /tmp/live-tripwire

@main
struct LiveTripwire {
    static func main() async {
        let seconds = 14.0
        let heartbeat = 3.0
        print("=== Растяжка: heartbeat \(Int(heartbeat)) с, наблюдаем \(Int(seconds)) с ===")

        let breaks = BreakCounter()
        let tripwire = TripwireConnection()
        await tripwire.start(heartbeatSeconds: heartbeat) {
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
            : "⚠ Были обрывы: \(count) — проверить дедлайн чтения и backoff")
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
