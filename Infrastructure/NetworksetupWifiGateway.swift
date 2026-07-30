import Foundation
import os

/// Эскалация ФТ-9: выключение Wi-Fi через `networksetup`. Root не требуется.
/// Имя устройства определяется динамически — на целевой машине это `en0`,
/// но хардкодить нельзя: у Ethernet-адаптеров имена соседние.
struct NetworksetupWifiGateway: WifiPowerGateway {
    enum WifiError: Error, CustomStringConvertible {
        case deviceNotFound
        case commandFailed(String)

        var description: String {
            switch self {
            case .deviceNotFound: "Wi-Fi-устройство не найдено в networksetup"
            case .commandFailed(let text): "networksetup вернул ошибку: \(text)"
            }
        }
    }

    private static let executable = "/usr/sbin/networksetup"
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "wifi")

    func turnWifiOff() async throws {
        let device = try wifiDevice()
        logger.log("выключаем Wi-Fi на устройстве \(device, privacy: .public)")
        let result = try run(["-setairportpower", device, "off"])
        guard result.code == 0 else { throw WifiError.commandFailed(result.output) }
    }

    /// Парсит вывод `-listallhardwareports`: блок «Hardware Port: Wi-Fi»
    /// и следующая за ним строка «Device: enN».
    func wifiDevice() throws -> String {
        let result = try run(["-listallhardwareports"])
        guard result.code == 0 else { throw WifiError.commandFailed(result.output) }
        guard let device = Self.parseWifiDevice(result.output) else {
            throw WifiError.deviceNotFound
        }
        return device
    }

    static func parseWifiDevice(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() where line.hasPrefix("Hardware Port:") {
            let port = line.dropFirst("Hardware Port:".count)
                .trimmingCharacters(in: .whitespaces)
            guard port == "Wi-Fi" || port == "AirPort" else { continue }
            guard let deviceLine = lines[(index + 1)...]
                .first(where: { $0.hasPrefix("Device:") }) else { continue }
            let device = deviceLine.dropFirst("Device:".count)
                .trimmingCharacters(in: .whitespaces)
            return device.isEmpty ? nil : device
        }
        return nil
    }

    private func run(_ arguments: [String]) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
