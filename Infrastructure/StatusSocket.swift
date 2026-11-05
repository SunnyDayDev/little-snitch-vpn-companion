import Darwin
import Foundation

/// Все системные вызовы неблокирующие; lock защищает от повторного использования закрытого fd.
final class StatusSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    static let requestLimit = 16 * 1024
    static let responseLimit = 4 * 1024 * 1024

    init(fd: Int32) throws {
        self.fd = fd
        guard fd >= 0 else { throw StatusFailure.unavailable }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            closeSocket()
            throw StatusFailure.unavailable
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            closeSocket()
            throw StatusFailure.unavailable
        }
    }
    convenience init() throws { try self.init(fd: socket(AF_UNIX, SOCK_STREAM, 0)) }
    deinit { closeSocket() }

    func access<T>(_ body: (Int32) throws -> T) throws -> T {
        try lock.withLock {
            guard fd >= 0 else { throw StatusFailure.unavailable }
            return try body(fd)
        }
    }
    var isClosed: Bool { lock.withLock { fd < 0 } }
    func closeSocket() {
        lock.withLock {
            if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        }
    }
    static func deadline(seconds: Double) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
    }
    static func checkDeadline(_ deadline: UInt64) throws {
        if DispatchTime.now().uptimeNanoseconds >= deadline { throw StatusFailure.timeout }
    }
    func wait(_ events: Int16, until deadline: UInt64) throws {
        while true {
            try Self.checkDeadline(deadline)
            let remaining = (deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000
            let ready = try access { fd -> Int32 in
                var item = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&item, 1, Int32(min(50, max(1, remaining))))
                if result > 0 && item.revents & (events | Int16(POLLHUP | POLLERR)) == 0 {
                    throw StatusFailure.unavailable
                }
                return result
            }
            if ready > 0 { return }
            if ready < 0 && errno != EINTR { throw StatusFailure.unavailable }
        }
    }
    func verifyPeer(expectedUID: uid_t = geteuid()) throws {
        try access { fd in
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, Self.accepts(uid: uid, expected: expectedUID) else {
                throw StatusFailure.unavailable
            }
        }
    }
    static func accepts(uid: uid_t, expected: uid_t) -> Bool { uid == expected }

    func connect(to endpoint: StatusEndpoint, until deadline: UInt64) throws {
        try endpoint.checkSocket()
        var address = try endpoint.address()
        let result = try access { fd in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw StatusFailure.unavailable }
            try wait(Int16(POLLOUT), until: deadline)
            try access { fd in
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                    throw StatusFailure.unavailable
                }
            }
        }
        try verifyPeer()
    }
    func listen(on endpoint: StatusEndpoint) throws {
        var address = try endpoint.address()
        try access { fd in
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(endpoint.path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
                throw StatusFailure.unavailable
            }
        }
    }
    func acceptClient() throws -> StatusSocket? {
        let client = try access { Darwin.accept($0, nil, nil) }
        if client < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
            throw StatusFailure.unavailable
        }
        return try StatusSocket(fd: client)
    }
    func writeFrame(_ data: Data, limit: Int, until deadline: UInt64) throws {
        guard !data.isEmpty, data.count <= limit else { throw StatusFailure.protocolError }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        var offset = 0
        while offset < frame.count {
            try wait(Int16(POLLOUT), until: deadline)
            let count = try access { fd in
                frame.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0) }
            }
            if count > 0 { offset += count }
            else if count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                throw StatusFailure.unavailable
            }
        }
    }
    func readFrame(limit: Int, until deadline: UInt64) throws -> Data {
        let header = try read(count: 4, until: deadline)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= limit else { throw StatusFailure.protocolError }
        return try read(count: Int(length), until: deadline)
    }
    private func read(count: Int, until deadline: UInt64) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(Int16(POLLIN), until: deadline)
            let received = try access { fd in
                data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            }
            if received > 0 { offset += received }
            else if received == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                throw StatusFailure.unavailable
            }
        }
        return data
    }
}
