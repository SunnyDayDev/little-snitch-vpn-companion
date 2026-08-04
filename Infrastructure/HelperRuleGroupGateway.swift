import Foundation
import os

/// XPC-клиент к привилегированному helper. Соединение поднимается лениво и
/// переустанавливается после сбоя: демон могли выгрузить или переустановить.
actor HelperRuleGroupGateway: RuleGroupGateway, FailsafeSyncing {
    private var connection: NSXPCConnection?
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "helper-xpc")

    func helperVersion() async throws -> String {
        try await withProxy { proxy, complete in
            proxy.version { complete(.success($0)) }
        }
    }

    func listRuleGroups() async throws -> [RuleGroup] {
        let data: Data = try await withProxy { proxy, complete in
            proxy.listRuleGroups { data, error in
                if let data {
                    complete(.success(data))
                } else {
                    let text = error ?? "пустой ответ helper"
                    // Запрет CLI со стороны Little Snitch — отдельный диагноз:
                    // helper тут исправен, чинить надо в настройках LS.
                    complete(.failure(text.localizedCaseInsensitiveContains("not authorized")
                        ? RuleGroupGatewayError.cliNotAuthorized
                        : .unparsableModel(text)))
                }
            }
        }
        let groups = try JSONDecoder().decode([HelperRuleGroup].self, from: data)
        return groups.map { RuleGroup(name: $0.name, enabled: $0.enabled) }
    }

    func setRuleGroup(_ name: String, enabled: Bool) async throws {
        try await withProxy { proxy, complete in
            proxy.setRuleGroup(name, enabled: enabled) { success, error in
                if success {
                    complete(.success(()))
                } else {
                    complete(.failure(RuleGroupGatewayError
                        .fromCLI(error ?? "неизвестная ошибка")))
                }
            }
        }
    }

    /// Failsafe-конфиг уезжает в helper как JSON (D5): контракт остаётся
    /// перечислимым, а расширение конфига не меняет сигнатуру операции.
    func syncFailsafe(_ config: FailsafeConfig) async throws {
        let data = try JSONEncoder().encode(config)
        try await withProxy { proxy, complete in
            proxy.setFailsafe(data) { success, error in
                if success {
                    complete(.success(()))
                } else {
                    complete(.failure(RuleGroupGatewayError
                        .failsafeRejected(error ?? "неизвестная ошибка")))
                }
            }
        }
    }

    /// Разорвать соединение — после переустановки helper старое непригодно.
    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Соединение

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // См. комментарий в HelperPresenceConnection: `@Sendable` нужен, чтобы
        // замыкание проходило как `sending`-параметр и на Xcode 26.3, и на 26.6.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { await self?.clearConnection() }
        }
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { await self?.clearConnection() }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func clearConnection() {
        connection = nil
    }

    /// Демон, зарегистрированный но не одобренный в Системных настройках, не
    /// отвечает и не сообщает об ошибке — вызов висел бы вечно, и приложение
    /// молчало бы вместо внятной ошибки.
    private static let callTimeoutSeconds = 6.0

    /// Оборачивает колбэчный XPC-вызов в async. Обрыв соединения приходит
    /// отдельным колбэком, поэтому резюмирование защищено от повторов.
    private func withProxy<T: Sendable>(
        _ body: @escaping @Sendable (any HelperProtocol,
                                     @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { [self] in try await self.callProxy(body) }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.callTimeoutSeconds))
                throw RuleGroupGatewayError.helperUnavailable(
                    "helper не ответил за \(Int(Self.callTimeoutSeconds)) с — "
                        + "возможно, он ждёт одобрения в Системных настройках")
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else {
                    throw RuleGroupGatewayError.helperUnavailable("нет ответа helper")
                }
                return first
            } catch {
                // Соединение, не дождавшееся ответа, остаётся негодным: без
                // сброса следующая попытка снова упирается в него, и одобрение
                // helper в Системных настройках остаётся незамеченным.
                invalidate()
                throw error
            }
        }
    }

    /// Вызов обязан быть отменяемым: XPC к неодобренному демону не отвечает и
    /// не сообщает об ошибке, а неотменяемая континуация задержала бы и группу
    /// с таймаутом — запрос завис бы молча.
    private func callProxy<T: Sendable>(
        _ body: @escaping @Sendable (any HelperProtocol,
                                     @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = makeConnection()
        let gate = OneShotContinuationBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.set(continuation)
                let handler = connection.remoteObjectProxyWithErrorHandler { error in
                    gate.resume(.failure(RuleGroupGatewayError
                        .helperUnavailable(String(describing: error))))
                }
                guard let proxy = handler as? any HelperProtocol else {
                    gate.resume(.failure(RuleGroupGatewayError
                        .helperUnavailable("не удалось получить прокси helper")))
                    return
                }
                body(proxy) { gate.resume($0) }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }
}

/// Континуация, которую безопасно резюмировать из нескольких источников:
/// колбэка XPC, обработчика ошибки соединения и обработчика отмены. Отмена
/// может прийти раньше, чем континуация установлена, — тогда результат
/// запоминается и применяется сразу при установке.
private final class OneShotContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pendingResult: Result<T, any Error>?
    private var isResumed = false

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let pendingResult, !isResumed {
            isResumed = true
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        guard !isResumed else {
            lock.unlock()
            return
        }
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        isResumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private struct HelperRuleGroup: Codable {
    let name: String
    let enabled: Bool
}
