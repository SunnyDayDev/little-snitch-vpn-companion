import Foundation
import Network
import os

/// Куда и что шлёт растяжка детектора: хост и путь — из URL его основного
/// маяка (D6 design.md), heartbeat — минимальный `GET <путь>` с keep-alive.
struct TripwireTarget: Hashable, Sendable {
    let host: String
    let port: UInt16
    let path: String
    let usesTLS: Bool

    init?(beaconURL: String) {
        guard let url = URL(string: beaconURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        usesTLS = scheme == "https"
        let defaultPort: UInt16 = usesTLS ? 443 : 80
        guard let port = url.port.map({ UInt16(exactly: $0) }) ?? defaultPort else { return nil }
        self.host = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        self.port = port
        let rawPath = url.path(percentEncoded: true)
        let query = url.query(percentEncoded: true).map { "?\($0)" } ?? ""
        path = (rawPath.isEmpty ? "/" : rawPath) + query
        defaultPortOmitted = port == defaultPort
    }

    private let defaultPortOmitted: Bool

    /// Значение заголовка Host: IPv6 — в скобках, нестандартный порт — явно.
    var hostHeader: String {
        let shown = host.contains(":") ? "[\(host)]" : host
        return defaultPortOmitted ? shown : "\(shown):\(port)"
    }

    var heartbeatRequest: String {
        "GET \(path) HTTP/1.1\r\n"
            + "Host: \(hostHeader)\r\n"
            + "User-Agent: LSVPNCompanion/1.0\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"
    }
}

/// Растяжки всех детекторов: по соединению на детектор. Смена сети
/// сбрасывает backoff всех растяжек сразу.
actor TripwirePool: TripwireMonitoring {
    private var connections: [DetectorID: TripwireConnection] = [:]

    func start(_ id: DetectorID,
               beaconURL: String,
               proxy: ProxyConfig,
               heartbeatSeconds: Double,
               onBreak: @escaping @Sendable () -> Void) async {
        await connections[id]?.stop()
        // URL, из которого не собрать адрес, растяжки не даёт: детектор
        // наблюдается только пробами, а проба по такому маяку — Offline.
        guard let target = TripwireTarget(beaconURL: beaconURL) else {
            connections[id] = nil
            return
        }
        let connection = connections[id] ?? TripwireConnection()
        connections[id] = connection
        await connection.start(target: target, proxy: proxy,
                               heartbeatSeconds: heartbeatSeconds, onBreak: onBreak)
    }

    func stop(_ id: DetectorID) async {
        await connections[id]?.stop()
        connections[id] = nil
    }

    func stopAll() async {
        for connection in connections.values { await connection.stop() }
        connections.removeAll()
    }

    func networkPathChanged() async {
        for connection in connections.values { await connection.networkPathChanged() }
    }
}

/// «Растяжка» (§4.2, слой 1): постоянное TLS-соединение к хосту маяка
/// детектора тем же путём, что и его пробы. Раз в `heartbeatSeconds` по нему
/// уходит крошечный запрос с дедлайном чтения 5 с. Любой обрыв — мгновенный
/// сигнал: перехватчик, терминировавший TCP на себе, виден сразу, без
/// ожидания плановой пробы.
///
/// URLSession здесь не годится: он прячет жизненный цикл соединения
/// (пулинг, прозрачные реконнекты), а нужен именно сырой сигнал разрыва.
actor TripwireConnection {
    private enum TripwireError: Error {
        case readDeadline
        case connectionFailed(String)
        case cancelled
    }

    private static let readDeadlineSeconds = 5.0
    private static let maxBackoffSeconds = 60.0

    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "tripwire")
    private let queue = DispatchQueue(label: "dev.sunnyday.lsvpncompanion.tripwire")

    private var connection: NWConnection?
    private var loop: Task<Void, Never>?
    private var onBreak: (@Sendable () -> Void)?
    private var target: TripwireTarget?
    private var proxy = ProxyConfig.direct
    private var heartbeatSeconds = 15.0
    private var backoffSeconds = 0.0
    private var isRunning = false
    /// Номер поколения растяжки: старый цикл после перезапуска не должен
    /// сигналить ложный обрыв и гасить уже новое соединение.
    private var generation = 0

    func start(target: TripwireTarget,
               proxy: ProxyConfig,
               heartbeatSeconds: Double,
               onBreak: @escaping @Sendable () -> Void) async {
        await stop()
        self.target = target
        self.proxy = proxy
        self.heartbeatSeconds = heartbeatSeconds
        self.onBreak = onBreak
        isRunning = true
        backoffSeconds = 0
        generation += 1
        let generation = generation
        loop = Task { [weak self] in await self?.run(generation: generation) }
    }

    func stop() async {
        isRunning = false
        loop?.cancel()
        loop = nil
        connection?.cancel()
        connection = nil
    }

    /// Смена сети — повод попробовать переустановиться немедленно, не досиживая
    /// накопленный backoff (D3 design.md).
    func networkPathChanged() async {
        backoffSeconds = 0
        connection?.cancel()
    }

    private func run(generation: Int) async {
        while isRunning, generation == self.generation, !Task.isCancelled {
            do {
                let connection = try await connect()
                guard generation == self.generation else {
                    connection.cancel()
                    return
                }
                self.connection = connection
                backoffSeconds = 0
                logger.debug("растяжка установлена")
                try await heartbeatLoop(connection)
            } catch {
                // Отработавшее поколение молчит: сигналить обрыв и гасить
                // соединение имеет право только текущее.
                guard isRunning, generation == self.generation else { return }
                logger.debug("растяжка оборвалась: \(String(describing: error), privacy: .public)")
                signalBreak()
            }
            guard generation == self.generation else { return }
            connection?.cancel()
            connection = nil
            guard isRunning else { return }
            await backoff()
        }
    }

    private func signalBreak() {
        onBreak?()
    }

    /// Экспоненциальный backoff 2 → 4 → 8 → … → 60 с, чтобы в офлайне
    /// не молотить сеть.
    private func backoff() async {
        backoffSeconds = backoffSeconds == 0
            ? 2
            : min(backoffSeconds * 2, Self.maxBackoffSeconds)
        try? await Task.sleep(for: .seconds(backoffSeconds))
    }

    private func connect() async throws -> NWConnection {
        guard let target, let port = NWEndpoint.Port(rawValue: target.port) else {
            throw TripwireError.connectionFailed("нет адреса маяка")
        }
        let parameters = target.usesTLS ? NWParameters.tls : NWParameters.tcp
        parameters.serviceClass = .responsiveData
        // Тот же путь, что у проб детектора: его прокси или напрямую, без
        // системных настроек прокси.
        ProxyRouting.apply(proxy, to: parameters)
        let connection = NWConnection(host: NWEndpoint.Host(target.host),
                                      port: port,
                                      using: parameters)
        let gate = ContinuationGate<Void>()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.succeed(())
                    case .failed(let error):
                        gate.fail(TripwireError.connectionFailed(String(describing: error)))
                    case .cancelled:
                        gate.fail(TripwireError.cancelled)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }

        return connection
    }

    private func heartbeatLoop(_ connection: NWConnection) async throws {
        let request = target?.heartbeatRequest ?? ""
        while isRunning && !Task.isCancelled {
            try await send(request, over: connection)
            _ = try await receiveWithDeadline(connection)
            try await Task.sleep(for: .seconds(heartbeatSeconds))
        }
        throw TripwireError.cancelled
    }

    private func send(_ text: String, over connection: NWConnection) async throws {
        let gate = ContinuationGate<Void>()
        try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            connection.send(content: Data(text.utf8),
                            completion: .contentProcessed { error in
                if let error {
                    gate.fail(TripwireError.connectionFailed(String(describing: error)))
                } else {
                    gate.succeed(())
                }
            })
        }
    }

    /// Дедлайн чтения превращает «тихо зависший путь при живом туннеле»
    /// в сигнал: ждать ответа дольше 5 с бессмысленно.
    private func receiveWithDeadline(_ connection: NWConnection) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await Self.receiveOnce(connection) }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.readDeadlineSeconds))
                throw TripwireError.readDeadline
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TripwireError.cancelled
            }
            return first
        }
    }

    /// `NWConnection.receive` сам по себе неотменяем: без обработчика отмены
    /// группа задач ждала бы его вечно, и дедлайн чтения не срабатывал бы —
    /// ровно в том случае, ради которого он нужен (путь тихо завис при живом
    /// туннеле). Отмена рвёт соединение, и колбэк приходит с ошибкой.
    private static func receiveOnce(_ connection: NWConnection) async throws -> Data {
        let gate = ContinuationGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.set(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                    data, _, isComplete, error in
                    if let error {
                        gate.fail(TripwireError.connectionFailed(String(describing: error)))
                    } else if isComplete {
                        // EOF: удалённая сторона закрыла соединение
                        gate.fail(TripwireError.connectionFailed("EOF"))
                    } else {
                        gate.succeed(data ?? Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
            gate.fail(TripwireError.cancelled)
        }
    }
}

/// Континуация, которую безопасно резюмировать из колбэков Network.framework:
/// они могут прийти повторно (например, ошибка после отмены), а двойной
/// resume — краш.
private final class ContinuationGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var isResumed = false

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func succeed(_ value: T) {
        guard let continuation = take() else { return }
        continuation.resume(returning: value)
    }

    func fail(_ error: any Error) {
        guard let continuation = take() else { return }
        continuation.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !isResumed, let continuation else { return nil }
        isResumed = true
        self.continuation = nil
        return continuation
    }
}
