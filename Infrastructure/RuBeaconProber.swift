import Foundation
import os

/// РУ-маяк (§4.4 SPEC.md): сервис в зоне `.ru` уходит мимо VPN благодаря
/// РУ-сплиту и потому видит реальный IP текущей сети. Оба endpoint'а
/// неофициальные — отсюда два кандидата и жёсткая валидация ответа.
struct RuBeaconProber: DirectIPProbing {
    /// 2ip.ru отдаёт голый text/plain только не-браузерному клиенту.
    private static let userAgent = "curl/8.7.1"

    private let settingsProvider: @Sendable () -> AppSettings
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "ru-beacon")

    init(settingsProvider: @escaping @Sendable () -> AppSettings) {
        self.settingsProvider = settingsProvider
    }

    func fetchDirectIP(timeout: Double) async -> IPAddress? {
        let settings = settingsProvider()
        for candidate in [settings.ruBeaconURL, settings.ruBeaconFallbackURL] {
            guard let url = URL(string: candidate) else { continue }
            guard Self.isRussianZone(url) else {
                logger.warning("РУ-маяк \(candidate, privacy: .public) не в зоне .ru — пропускаем")
                continue
            }
            if let ip = await fetch(url, timeout: timeout) { return ip }
        }
        return nil
    }

    /// Домен обязан быть в зоне `.ru`: иначе запрос уйдёт через VPN и вернёт
    /// не прямой IP, а egress цепочки.
    static func isRussianZone(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "ru" || host.hasSuffix(".ru")
    }

    private func fetch(_ url: URL, timeout: Double) async -> IPAddress? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = String(data: data, encoding: .utf8) else { return nil }
            return Self.parse(body)
        } catch {
            logger.debug("РУ-маяк \(url.absoluteString, privacy: .public) недоступен")
            return nil
        }
    }

    /// yandex отдаёт JSON-строку `"<ip>"`, 2ip.ru — голый IP. Всё, что после
    /// разбора не является IP-адресом, отбрасывается.
    static func parse(_ body: String) -> IPAddress? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return IPAddress(text)
    }
}
