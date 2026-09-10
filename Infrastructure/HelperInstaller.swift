import Foundation
import ServiceManagement
import os

/// Адаптер порта `HelperRegistrar` поверх `SMAppService.daemon`. Здесь только
/// вызовы системы: ожидания, повторы и полный цикл снятия и регистрации живут
/// в `HelperLifecycle`. Одобряет пользователь в System Settings → Основные →
/// Объекты входа (шаг 1 онбординга).
struct HelperInstaller: HelperRegistrar {
    private static let plistName = "dev.sunnyday.lsvpncompanion.helper.plist"
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "helper-install")

    private var service: SMAppService { .daemon(plistName: Self.plistName) }

    /// Отражает базу Background Task Management, а не launchd: после
    /// `register()` статус уже `enabled`, а демон поднимается ещё десятки
    /// секунд (замер 2026-09-09: 30 с).
    var status: HelperRegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }

    /// `register()` поверх `.enabled` обновляет launch constraint (LWCR) без
    /// снятия регистрации — так launchd узнаёт о пересобранном бинаре.
    func register() throws {
        try service.register()
        logger.log("helper зарегистрирован, статус: \(String(describing: service.status), privacy: .public)")
    }

    /// Завершается асинхронно на стороне системы: `register()` сразу после
    /// снятия отменяется им. Ожидание фактического `.notRegistered` — в
    /// `HelperLifecycle`.
    func unregister() async throws {
        try await service.unregister()
    }

    func openApprovalSettings() async {
        await MainActor.run { SMAppService.openSystemSettingsLoginItems() }
    }

    /// `launchctl print system/<label>` доступен без root: код 0 — job есть,
    /// 113 — «Could not find service». Любой другой код — сигнала нет
    /// (например, ужесточили права), и ждать выгрузку по нему нельзя.
    func isJobLoaded() async -> Bool? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "system/\(HelperConstants.machServiceName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                switch finished.terminationStatus {
                case 0: continuation.resume(returning: true)
                case 113: continuation.resume(returning: false)
                default: continuation.resume(returning: nil)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Версия helper, лежащего в бандле приложения. Если работающий демон
    /// сообщает другую — launchd держит в памяти устаревший бинарь, и его надо
    /// переустановить.
    var bundledVersion: String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(HelperConstants.helperExecutableName)
            .path
        return HelperConstants.version(ofExecutableAt: path)
    }
}
