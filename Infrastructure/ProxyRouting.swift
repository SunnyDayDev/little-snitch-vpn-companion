import Foundation
import Network

/// Путь детектора к маяку (D5 design.md): `ProxyConfiguration` Network.framework
/// для URLSession и NWParameters. Системные настройки прокси не используются
/// ни в одном случае: детектор без прокси ходит напрямую, а детектор с
/// прокси без права откатиться на прямое соединение — иначе мёртвый прокси
/// показал бы egress машины вместо Offline.
enum ProxyRouting {
    static func endpoint(for proxy: ProxyConfig) -> NWEndpoint? {
        guard !proxy.isDirect, !proxy.host.isEmpty,
              (1...65_535).contains(proxy.port),
              let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
    }

    /// Пусто — прямой путь (или прокси без адреса: такой пробе не дойти).
    static func proxyConfigurations(for proxy: ProxyConfig) -> [ProxyConfiguration] {
        guard let endpoint = endpoint(for: proxy) else { return [] }
        var configuration = switch proxy.kind {
        case .socks5: ProxyConfiguration(socksv5Proxy: endpoint)
        case .httpConnect: ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .direct: ProxyConfiguration(socksv5Proxy: endpoint)
        }
        configuration.allowFailover = false
        return [configuration]
    }

    static func apply(_ proxy: ProxyConfig, to configuration: URLSessionConfiguration) {
        let proxies = proxyConfigurations(for: proxy)
        configuration.proxyConfigurations = proxies
        // Пустой словарь вместо nil: nil означает «системные настройки».
        if proxies.isEmpty { configuration.connectionProxyDictionary = [:] }
    }

    static func apply(_ proxy: ProxyConfig, to parameters: NWParameters) {
        let proxies = proxyConfigurations(for: proxy)
        guard !proxies.isEmpty else {
            parameters.preferNoProxies = true
            return
        }
        let context = NWParameters.PrivacyContext(description: "lsvpncompanion-detector")
        context.proxyConfigurations = proxies
        parameters.setPrivacyContext(context)
    }
}
