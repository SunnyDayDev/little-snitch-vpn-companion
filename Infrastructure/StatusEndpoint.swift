import Darwin
import Foundation

/// Путь определяется ОС для UID, а не окружением запуска терминала.
struct StatusEndpoint: Sendable {
    let directory: String
    var path: String { directory + "/status.sock" }

    static func current() throws -> StatusEndpoint {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { throw StatusFailure.unavailable }
        let path = String(decoding: buffer.prefix(Int(length) - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return StatusEndpoint(directory: path.hasSuffix("/") ? path + "lsvpn" : path + "/lsvpn")
    }

    func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw StatusFailure(code: .failure, message: "Слишком длинный путь локального канала статуса")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        return address
    }

    func prepare() throws {
        _ = try address()
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw StatusFailure.unavailable }
        try Self.check(path: directory, type: mode_t(S_IFDIR), permissions: 0o700)
    }

    func checkSocket() throws {
        try Self.check(path: directory, type: mode_t(S_IFDIR), permissions: 0o700)
        try Self.check(path: path, type: mode_t(S_IFSOCK), permissions: 0o600)
    }

    static func check(path: String, type: mode_t, permissions: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == type,
              info.st_mode & 0o777 == permissions else { throw StatusFailure.unavailable }
    }
}

/// Блокировка не удаляется: новый inode lock-файла позволил бы второму серверу захватить путь.
final class StatusEndpointLease: @unchecked Sendable {
    let endpoint: StatusEndpoint
    private let lockFD: Int32
    private var socketIdentity: (dev_t, ino_t)?

    init(endpoint: StatusEndpoint) throws {
        try endpoint.prepare()
        let fd = open(endpoint.directory + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StatusFailure.unavailable }
        var ownsDescriptor = false
        defer { if !ownsDescriptor { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw StatusFailure(code: .unavailable, message: "Локальный канал занят или недоступен")
        }
        var previous = stat()
        if lstat(endpoint.path, &previous) == 0 {
            try endpoint.checkSocket()
            guard unlink(endpoint.path) == 0 else { throw StatusFailure.unavailable }
        } else if errno != ENOENT {
            throw StatusFailure.unavailable
        }
        lockFD = fd
        self.endpoint = endpoint
        ownsDescriptor = true
    }

    func recordSocket() throws {
        var info = stat()
        guard lstat(endpoint.path, &info) == 0 else { throw StatusFailure.unavailable }
        socketIdentity = (info.st_dev, info.st_ino)
    }

    deinit {
        if let identity = socketIdentity {
            var info = stat()
            if lstat(endpoint.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 {
                unlink(endpoint.path)
            }
        }
        close(lockFD)
    }
}
