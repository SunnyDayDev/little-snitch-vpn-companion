import Darwin
import Foundation

/// Отдельные очереди обслуживают сокеты; actor мониторинга вызывается только для копии данных.
final class StatusServer: StatusServing, @unchecked Sendable {
    typealias Reader = @Sendable (String?) async throws -> StatusDocument
    private let lock = NSLock()
    private var session: Session?
    private let endpoint: StatusEndpoint?
    private let reader: Reader
    private let timeout: Double

    init(endpoint: StatusEndpoint? = nil, timeout: Double = 3, reader: @escaping Reader) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.reader = reader
    }
    func start() throws {
        try lock.withLock {
            guard session == nil else { return }
            let lease = try StatusEndpointLease(endpoint: endpoint ?? StatusEndpoint.current())
            let listener = try StatusSocket()
            try listener.listen(on: lease.endpoint)
            try lease.recordSocket()
            let session = Session(listener: listener, lease: lease, timeout: timeout, reader: reader)
            self.session = session
            DispatchQueue.global(qos: .utility).async { session.run() }
        }
    }
    func stop() {
        lock.withLock { session?.stop(); session = nil }
    }
    deinit { stop() }

    private final class Session: @unchecked Sendable {
        let listener: StatusSocket
        private var lease: StatusEndpointLease?
        let timeout: Double
        let reader: Reader
        let lock = NSLock()
        var clients: [UUID: StatusSocket] = [:]
        var stopped = false

        init(listener: StatusSocket, lease: StatusEndpointLease, timeout: Double, reader: @escaping Reader) {
            self.listener = listener; self.lease = lease; self.timeout = timeout; self.reader = reader
        }
        func run() {
            while !listener.isClosed {
                do {
                    try listener.wait(Int16(POLLIN), until: StatusSocket.deadline(seconds: 0.1))
                    guard let client = try listener.acceptClient() else { continue }
                    let id = UUID()
                    let admitted = lock.withLock {
                        guard !stopped, clients.count < 16 else { return false }
                        clients[id] = client
                        return true
                    }
                    if admitted {
                        DispatchQueue.global(qos: .utility).async { self.serve(client, id: id) }
                    } else { client.closeSocket() }
                } catch { continue }
            }
        }
        func stop() {
            lock.withLock {
                stopped = true
                listener.closeSocket()
                for client in clients.values { client.closeSocket() }
                clients.removeAll()
                lease = nil
            }
        }
        func serve(_ client: StatusSocket, id: UUID) {
            defer { client.closeSocket(); _ = lock.withLock { clients.removeValue(forKey: id) } }
            let deadline = StatusSocket.deadline(seconds: timeout)
            do {
                try client.verifyPeer()
                let data = try client.readFrame(limit: StatusSocket.requestLimit, until: deadline)
                let response: StatusResponse
                do {
                    let request = try JSONDecoder().decode(StatusRequest.self, from: data)
                    guard request.schemaVersion == 1, request.command == "status" else { throw StatusFailure.protocolError }
                    let pending = Pending()
                    let task = Task { [reader] in
                        let result: Result<StatusDocument, any Error>
                        do { result = .success(try await reader(request.detectorID)) }
                        catch { result = .failure(error) }
                        pending.set(result)
                    }
                    defer { task.cancel() }
                    while pending.get() == nil {
                        try StatusSocket.checkDeadline(deadline)
                        if client.isClosed { throw StatusFailure.unavailable }
                        _ = pending.ready.wait(timeout: .now() + .milliseconds(10))
                    }
                    response = StatusResponse(result: try pending.get()!.get(), error: nil)
                } catch {
                    let failure = error as? StatusFailure ?? StatusFailure.protocolError
                    response = StatusResponse(result: nil, error: failure)
                }
                try client.writeFrame(JSONEncoder().encode(response), limit: StatusSocket.responseLimit, until: deadline)
            } catch { /* Ошибки клиента не влияют на мониторинг и не засоряют журнал. */ }
        }
    }

    private final class Pending: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Result<StatusDocument, any Error>?
        func set(_ value: Result<StatusDocument, any Error>) { lock.withLock { self.value = value }; ready.signal() }
        func get() -> Result<StatusDocument, any Error>? { lock.withLock { value } }
    }
}
