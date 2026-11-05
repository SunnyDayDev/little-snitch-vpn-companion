import Darwin
import Foundation
import Testing

@Suite("Локальный канал статуса", .serialized)
struct StatusServerTests {
    private func endpoint() -> StatusEndpoint {
        StatusEndpoint(directory: "/tmp/lsvpn-" + UUID().uuidString)
    }
    private func remove(_ endpoint: StatusEndpoint) { try? FileManager.default.removeItem(atPath: endpoint.directory) }
    private static func document(_ id: String?) -> StatusDocument {
        let detector = StatusDetector(id: "one", name: "Основной", isEnabled: false, mode: .strict,
                                      state: .disabled, explanation: nil, lastCheck: nil,
                                      tripwireActive: false, assignedGroups: [])
        return StatusDocument(capturedAt: StatusDocument.timestamp(100), monitoring: .paused,
            observeOnly: true, helperUnavailable: true, groups: StatusGroups(known: true, active: []),
            overall: id == nil ? StatusOverall(state: .paused, culpritID: nil,
                hasEnabledDetectors: false, hasStrictClosed: false) : nil,
            detectors: id == nil ? [detector] : nil, detector: id == nil ? nil : detector)
    }
    private func server(_ endpoint: StatusEndpoint) -> StatusServer {
        StatusServer(endpoint: endpoint) { id in
            if let id, id != "one" { throw StatusFailure(code: .detectorNotFound, message: "Детектор не найден") }
            return Self.document(id)
        }
    }

    @Test("Полный и выбранный статус, повторный старт, недоступный helper")
    func roundTrip() throws {
        let point = endpoint()
        defer { remove(point) }
        let service = server(point)
        defer { service.stop() }
        try service.start()
        try service.start()
        let client = StatusClient(endpoint: point)
        #expect(try client.read(detectorID: nil).detectors?.count == 1)
        #expect(try client.read(detectorID: "one").detector?.state == .disabled)
        #expect(try client.read(detectorID: nil).monitoring == .paused)
        do { _ = try client.read(detectorID: "absent"); Issue.record("Ожидалась ошибка ID") }
        catch let error as StatusFailure { #expect(error.code == .detectorNotFound) }
        service.stop()
        #expect(throws: StatusFailure.self) { try client.read(detectorID: nil) }
        try service.start()
        #expect(try client.read(detectorID: nil).helperUnavailable)
    }

    @Test("Второй сервер не перехватывает живой сокет")
    func ownership() throws {
        let point = endpoint()
        defer { remove(point) }
        let first = server(point)
        let second = server(point)
        defer { first.stop(); second.stop() }
        try first.start()
        #expect(throws: StatusFailure.self) { try second.start() }
        #expect(try StatusClient(endpoint: point).read(detectorID: "one").detector?.id == "one")
        first.stop()
        try second.start()
        #expect(try StatusClient(endpoint: point).read(detectorID: nil).detectors?.count == 1)
    }

    @Test("Остаток собственного сокета после аварии восстанавливается")
    func staleSocket() throws {
        let point = endpoint()
        defer { remove(point) }
        try point.prepare()
        let abandoned = try StatusSocket()
        try abandoned.listen(on: point)
        abandoned.closeSocket()
        let service = server(point)
        defer { service.stop() }
        try service.start()
        #expect(try StatusClient(endpoint: point).read(detectorID: nil).monitoring == .paused)
    }

    @Test("Симлинки, неверные права и типы не принимаются")
    func unsafePaths() throws {
        let point = endpoint()
        let target = endpoint()
        defer { remove(point); remove(target) }
        try target.prepare()
        try FileManager.default.createSymbolicLink(atPath: point.directory, withDestinationPath: target.directory)
        #expect(throws: StatusFailure.self) { try point.prepare() }
        try FileManager.default.removeItem(atPath: point.directory)
        try point.prepare()
        #expect(chmod(point.directory, 0o755) == 0)
        #expect(throws: StatusFailure.self) { try point.prepare() }
        #expect(chmod(point.directory, 0o700) == 0)
        try Data().write(to: URL(fileURLWithPath: point.path))
        #expect(throws: StatusFailure.self) { try StatusEndpointLease(endpoint: point) }
        #expect(FileManager.default.fileExists(atPath: point.path))
        try FileManager.default.removeItem(atPath: point.path)
        try FileManager.default.createSymbolicLink(atPath: point.path, withDestinationPath: target.directory)
        #expect(throws: StatusFailure.self) { try StatusEndpointLease(endpoint: point) }
        #expect(throws: StatusFailure.self) { try StatusEndpoint(directory: "/tmp/" + String(repeating: "x", count: 150)).address() }
        #expect(StatusSocket.accepts(uid: 501, expected: 501))
        #expect(!StatusSocket.accepts(uid: 502, expected: 501))
    }

    @Test("Зависший поставщик ограничен дедлайном, остановка не ждёт клиента")
    func timeoutAndStop() throws {
        let point = endpoint()
        defer { remove(point) }
        let service = StatusServer(endpoint: point, timeout: 0.1) { id in
            try await Task.sleep(for: .seconds(30))
            return Self.document(id)
        }
        try service.start()
        defer { service.stop() }
        do { _ = try StatusClient(endpoint: point, timeout: 0.05).read(detectorID: nil); Issue.record("Ожидался таймаут") }
        catch let error as StatusFailure { #expect(error.code == .unavailable) }
        let partial = try StatusSocket()
        try partial.connect(to: point, until: StatusSocket.deadline(seconds: 1))
        defer { partial.closeSocket() }
        let start = DispatchTime.now().uptimeNanoseconds
        service.stop()
        #expect(DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000)
        let replacement = server(point)
        defer { replacement.stop() }
        try replacement.start()
        #expect(try StatusClient(endpoint: point).read(detectorID: nil).monitoring == .paused)
    }

    @Test("Параллельные клиенты получают независимые ответы")
    func concurrent() async throws {
        let point = endpoint()
        defer { remove(point) }
        let service = server(point)
        defer { service.stop() }
        try service.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let id: String? = index.isMultiple(of: 2) ? nil : "one"
                    let value = try StatusClient(endpoint: point).read(detectorID: id)
                    try value.validate(detectorID: id)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("Фрагменты кадра и ограничения длины")
    func framing() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let sender = try StatusSocket(fd: fds[0])
        let receiver = try StatusSocket(fd: fds[1])
        defer { sender.closeSocket(); receiver.closeSocket() }
        let deadline = StatusSocket.deadline(seconds: 2)
        let payload = Data(repeating: 42, count: 100_000)
        DispatchQueue.global().async {
            var length = UInt32(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(payload)
            for part in frame {
                var byte = part
                _ = try? sender.access { send($0, &byte, 1, 0) }
            }
        }
        #expect(try receiver.readFrame(limit: 200_000, until: deadline) == payload)
        #expect(throws: StatusFailure.self) { try sender.writeFrame(payload, limit: 10, until: deadline) }
        var oversized = UInt32(200_001).bigEndian
        _ = try sender.access { fd in withUnsafeBytes(of: &oversized) { send(fd, $0.baseAddress, 4, 0) } }
        #expect(throws: StatusFailure.self) { try receiver.readFrame(limit: 200_000, until: deadline) }
    }

    @Test("Несовместимые и повреждённые ответы", arguments: ["version", "json", "truncated", "oversized"])
    func invalidResponse(_ kind: String) throws {
        let point = endpoint()
        defer { remove(point) }
        let lease = try StatusEndpointLease(endpoint: point)
        let listener = try StatusSocket()
        defer { listener.closeSocket(); withExtendedLifetime(lease) {} }
        try listener.listen(on: point)
        try lease.recordSocket()
        DispatchQueue.global().async {
            let deadline = StatusSocket.deadline(seconds: 2)
            do {
                try listener.wait(Int16(POLLIN), until: deadline)
                guard let client = try listener.acceptClient() else { return }
                defer { client.closeSocket() }
                _ = try client.readFrame(limit: StatusSocket.requestLimit, until: deadline)
                if kind == "oversized" {
                    var length = UInt32(StatusSocket.responseLimit + 1).bigEndian
                    _ = try client.access { fd in withUnsafeBytes(of: &length) { send(fd, $0.baseAddress, 4, 0) } }
                } else if kind == "truncated" {
                    var length = UInt32(100).bigEndian
                    _ = try client.access { fd in withUnsafeBytes(of: &length) { send(fd, $0.baseAddress, 4, 0) } }
                } else {
                    var response = StatusResponse(result: Self.document(nil), error: nil)
                    response.schemaVersion = 9
                    let body = kind == "json" ? Data("invalid".utf8) : try JSONEncoder().encode(response)
                    try client.writeFrame(body, limit: StatusSocket.responseLimit, until: deadline)
                }
            } catch { Issue.record("Ошибка тестового сервера: \(error)") }
        }
        do { _ = try StatusClient(endpoint: point).read(detectorID: nil); Issue.record("Ожидалась ошибка") }
        catch let error as StatusFailure { #expect(error.code == (kind == "truncated" ? .unavailable : .incompatible)) }
    }
}
