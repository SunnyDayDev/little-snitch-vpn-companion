import Foundation
import Network
import os

/// События сетевого пути (§4.2, слой 2): интерфейсы, шлюз, появление или
/// исчезновение utun. Схлопывание шквала событий делает координатор — здесь
/// только доставка.
actor SystemPathMonitor: PathMonitoring {
    private let queue = DispatchQueue(label: "dev.sunnyday.lsvpncompanion.path")
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "path")
    /// `NWPathMonitor` одноразовый: после `cancel()` он больше не отдаёт
    /// события. Поэтому на каждый запуск создаём новый — иначе после паузы
    /// второй слой детектора умирал бы навсегда.
    private var monitor: NWPathMonitor?

    func start(onChange: @escaping @Sendable (NetworkPathInfo) -> Void) async {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            onChange(Self.describe(path))
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        logger.debug("монитор сетевого пути запущен")
    }

    func stop() async {
        monitor?.cancel()
        monitor = nil
    }

    private static func describe(_ path: NWPath) -> NetworkPathInfo {
        var parts: [String] = []
        if path.usesInterfaceType(.wifi) { parts.append("Wi-Fi") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("Ethernet") }
        if path.usesInterfaceType(.cellular) { parts.append("сотовая") }
        if path.usesInterfaceType(.other) {
            // utun VPN-клиента проходит как .other — полезный признак для UI
            parts.append("туннель")
        }
        if parts.isEmpty { parts.append(path.status == .satisfied ? "неизвестный" : "нет сети") }

        let gateway = path.gateways.first.map(Self.describeEndpoint)
        return NetworkPathInfo(isSatisfied: path.status == .satisfied,
                               interfaceDescription: parts.joined(separator: " + "),
                               gateway: gateway)
    }

    private static func describeEndpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address): "\(address)"
            case .ipv6(let address): "\(address)"
            case .name(let name, _): name
            @unknown default: "\(endpoint)"
            }
        default:
            "\(endpoint)"
        }
    }
}
