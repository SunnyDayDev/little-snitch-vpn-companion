import Foundation
import Network
import os

/// Свежая проба маяка детектора (§4.2, слой 3). Каждый вызов — новая
/// ephemeral сессия: ни кэша, ни переиспользования соединений, иначе проба
/// показала бы состояние старого пути, а не текущего. URL, формат и прокси —
/// детектора; резервный маяк ходит тем же путём, что и основной.
struct BeaconProber: BeaconProbing {
    private let settingsProvider: @Sendable () -> AppSettings
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "beacon")

    init(settingsProvider: @escaping @Sendable () -> AppSettings = { AppSettings() }) {
        self.settingsProvider = settingsProvider
    }

    func fetchTrace(for detector: DetectorConfig, timeout: Double) async -> BeaconFetch {
        if let debugBody = debugFakeBody(format: detector.beacon.format) { return .body(debugBody) }
        // Прокси без адреса — не повод идти напрямую: egress машины вместо
        // выхода прокси дал бы ложный вердикт. Пробы нет — Offline.
        guard detector.proxy.isDirect || ProxyRouting.endpoint(for: detector.proxy) != nil else {
            return .offline(.networkFailure)
        }

        let primary = await fetch(detector.beacon.primaryURL, proxy: detector.proxy, timeout: timeout)
        if case .body = primary { return primary }

        // Резервный маяк по умолчанию — по IP, чтобы не зависеть от DNS
        guard let fallbackURL = detector.beacon.fallbackURL, !fallbackURL.isEmpty else {
            return primary
        }
        logger.debug("основной маяк не ответил, пробуем резервный")
        let fallback = await fetch(fallbackURL, proxy: detector.proxy, timeout: timeout)
        if case .body = fallback { return fallback }
        return primary
    }

    /// Скрытый debug-режим для приёмки (сценарии 13–14 §14 SPEC.md): подменяем
    /// egress у всех детекторов, оставляя остальные поля правдоподобными.
    private func debugFakeBody(format: BeaconFormat) -> String? {
        guard let fake = settingsProvider().debugFakeEgressIP, !fake.isEmpty else {
            return nil
        }
        switch format {
        case .cdnCgiTrace: return "ip=\(fake)\nwarp=on\ncolo=DBG\nloc=XX"
        case .plainIP: return fake
        }
    }

    private func fetch(_ urlString: String, proxy: ProxyConfig, timeout: Double) async -> BeaconFetch {
        guard let url = URL(string: urlString) else { return .offline(.networkFailure) }
        let session = URLSession(configuration: Self.sessionConfiguration(proxy: proxy,
                                                                          timeout: timeout))
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        request.setValue("close", forHTTPHeaderField: "Connection")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .offline(.unparsableResponse)
            }
            guard let body = String(data: data, encoding: .utf8) else {
                return .offline(.unparsableResponse)
            }
            return .body(body)
        } catch {
            return .offline(Self.classify(error))
        }
    }

    /// Сессия пробы: без кэша и пулинга, путь — прокси детектора или прямой.
    static func sessionConfiguration(proxy: ProxyConfig, timeout: Double) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        ProxyRouting.apply(proxy, to: configuration)
        return configuration
    }

    /// Любая ошибка пробы — Offline, не утечка: таймаут, сеть, TLS, отказ
    /// прокси (CFNetwork-домен SOCKS и CONNECT тоже сюда).
    static func classify(_ error: any Error) -> OfflineReason {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .networkFailure }
        return switch nsError.code {
        case NSURLErrorTimedOut: .timeout
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorCannotLoadFromNetwork: .tlsFailure
        default: .networkFailure
        }
    }
}
