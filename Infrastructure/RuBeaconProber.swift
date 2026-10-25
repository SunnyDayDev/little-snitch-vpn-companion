import Foundation
import os

/// РУ-маяк (§4.4 SPEC.md): сервис в зоне `.ru` уходит мимо VPN благодаря
/// РУ-сплиту и потому видит реальный IP текущей сети. Оба endpoint'а
/// неофициальные — отсюда два кандидата и жёсткая валидация ответа. Прямой
/// IP один на машину: запрос идёт напрямую, без прокси какого-либо детектора.
struct RuBeaconProber: DirectIPProbing {
    /// Не-браузерный клиент: сервисы «какой у меня IP» отдают ему голый
    /// text/plain, а не страницу.
    private static let userAgent = "curl/8.7.1"

    private let settingsProvider: @Sendable () -> AppSettings
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "ru-beacon")

    init(settingsProvider: @escaping @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func fetchDirectIP(timeout: Double) async -> DirectIPResult {
        let settings = settingsProvider()
        var rejected: [DirectIPRejection] = []
        for candidate in [settings.ruBeaconURL, settings.ruBeaconFallbackURL] {
            guard let url = URL(string: candidate) else { continue }
            guard Self.isRussianZone(url) else {
                logger.warning("РУ-маяк \(candidate, privacy: .public) не в зоне .ru — пропускаем")
                continue
            }
            guard let ip = await fetch(url, timeout: timeout) else { continue }
            // Сервис снаружи не может увидеть loopback, частный или fake-IP
            // адрес: такой ответ — подмена по пути, пробуем резервный.
            guard ip.isGloballyRoutable else {
                rejected.append(DirectIPRejection(beaconURL: candidate, address: ip))
                continue
            }
            return DirectIPResult(address: ip, rejected: rejected)
        }
        return DirectIPResult(address: nil, rejected: rejected)
    }

    /// Сессия РУ-маяка — напрямую: системный прокси macOS и прокси
    /// детекторов к прямому IP сети отношения не имеют. От прокси-клиента с
    /// TUN (Surge в расширенном режиме) это не спасает — его маршрутизация
    /// приложению неподвластна, поэтому ответ ещё и проверяется на
    /// маршрутизируемость.
    static func sessionConfiguration(timeout: Double) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        ProxyRouting.apply(.direct, to: configuration)
        return configuration
    }

    /// Домен обязан быть в зоне `.ru`: иначе запрос уйдёт через VPN и вернёт
    /// не прямой IP, а egress цепочки.
    static func isRussianZone(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "ru" || host.hasSuffix(".ru")
    }

    private func fetch(_ url: URL, timeout: Double) async -> IPAddress? {
        let session = URLSession(configuration: Self.sessionConfiguration(timeout: timeout))
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = String(data: data, encoding: .utf8) else { return nil }
            // yandex отдаёт JSON-строку `"<ip>"`, ip.beget.ru — голый IP: тот же
            // доменный разбор, что у маяков детекторов формата «голый IP».
            return PlainIPParser.parse(body)
        } catch {
            logger.debug("РУ-маяк \(url.absoluteString, privacy: .public) недоступен")
            return nil
        }
    }

}
