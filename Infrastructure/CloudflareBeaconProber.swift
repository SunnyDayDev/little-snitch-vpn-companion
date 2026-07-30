import Foundation
import os

/// Свежая проба foreign-маяка (§4.2, слой 3). Каждый вызов — новая ephemeral
/// сессия: ни кэша, ни переиспользования соединений, иначе проба показала бы
/// состояние старого пути, а не текущего.
struct CloudflareBeaconProber: BeaconProbing {
    private let primaryURL: URL
    private let fallbackURL: URL
    private let settingsProvider: @Sendable () -> AppSettings
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "beacon")

    init(primary: String = "https://www.cloudflare.com/cdn-cgi/trace",
         fallback: String = "https://1.1.1.1/cdn-cgi/trace",
         settingsProvider: @escaping @Sendable () -> AppSettings = { AppSettings() }) {
        primaryURL = URL(string: primary)!
        fallbackURL = URL(string: fallback)!
        self.settingsProvider = settingsProvider
    }

    func fetchTrace(timeout: Double) async -> BeaconFetch {
        if let debugBody = debugFakeBody() { return .body(debugBody) }

        let primary = await fetch(primaryURL, timeout: timeout)
        if case .body = primary { return primary }

        // Резервный маяк — по IP, чтобы не зависеть от DNS
        logger.debug("основной маяк не ответил, пробуем резервный")
        let fallback = await fetch(fallbackURL, timeout: timeout)
        if case .body = fallback { return fallback }
        return primary
    }

    /// Скрытый debug-режим для приёмки (сценарии 13–14 §14 SPEC.md): подменяем
    /// egress, оставляя остальные поля правдоподобными.
    private func debugFakeBody() -> String? {
        guard let fake = settingsProvider().debugFakeEgressIP, !fake.isEmpty else {
            return nil
        }
        return "ip=\(fake)\nwarp=on\ncolo=DBG\nloc=XX"
    }

    private func fetch(_ url: URL, timeout: Double) async -> BeaconFetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
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
