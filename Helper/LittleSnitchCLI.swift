import Foundation
import os

/// Вызовы `littlesnitch` CLI. Единственный компонент с правами root; знает
/// ровно один путь к бинарю и три операции.
///
/// Проверено на целевой машине 2026-07-29: без root CLI печатает
/// `littlesnitch must be run as root!` и завершается с кодом 14 — то есть
/// ненулевой код надо разбирать вместе с выводом, а не по коду.
struct LittleSnitchCLI {
    struct Result {
        let exitCode: Int32
        let output: String
    }

    enum CLIError: Error, CustomStringConvertible {
        case notInstalled
        case timedOut(seconds: Double)
        case failed(exitCode: Int32, output: String)

        var description: String {
            switch self {
            case .notInstalled:
                "littlesnitch не найден по пути \(HelperConstants.littlesnitchPath)"
            case .timedOut(let seconds):
                "littlesnitch не ответил за \(Int(seconds)) с"
            case .failed(let exitCode, let output):
                "littlesnitch завершился с кодом \(exitCode): \(output)"
            }
        }
    }

    static let timeoutSeconds = 3.0

    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "cli")

    func exportModel() throws -> Data {
        let result = try run(["export-model"])
        guard result.exitCode == 0 else {
            throw CLIError.failed(exitCode: result.exitCode, output: result.output)
        }
        return Data(result.output.utf8)
    }

    func setRuleGroup(_ name: String, enabled: Bool) throws {
        let result = try run([enabled ? "-e" : "-d", name], subcommand: "rulegroup")
        guard result.exitCode == 0 else {
            throw CLIError.failed(exitCode: result.exitCode, output: result.output)
        }
    }

    private func run(_ arguments: [String], subcommand: String? = nil) throws -> Result {
        let path = HelperConstants.littlesnitchPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CLIError.notInstalled
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = (subcommand.map { [$0] } ?? []) + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Читаем в фоне: большая модель не должна упереться в буфер пайпа.
        let collector = OutputCollector()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(chunk)
            }
        }

        let deadline = Date().addingTimeInterval(Self.timeoutSeconds)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            handle.readabilityHandler = nil
            logger.error("littlesnitch превысил таймаут \(Self.timeoutSeconds, privacy: .public) с")
            throw CLIError.timedOut(seconds: Self.timeoutSeconds)
        }

        process.waitUntilExit()
        handle.readabilityHandler = nil
        collector.append(handle.availableData)

        let output = String(decoding: collector.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(exitCode: process.terminationStatus, output: output)
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.append(chunk)
    }
}
