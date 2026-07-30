import Foundation
import ServiceManagement
import os

/// Регистрация привилегированного helper через `SMAppService.daemon`.
/// Одобряет пользователь в System Settings → Основные → Объекты входа
/// (шаг 1 онбординга).
struct HelperInstaller: Sendable {
    enum Status: Hashable, Sendable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound

        var isReady: Bool { self == .enabled }

        var description: String {
            switch self {
            case .notRegistered: "не установлен"
            case .requiresApproval: "ждёт одобрения в Системных настройках"
            case .enabled: "подключён · root"
            case .notFound: "не найден в бандле"
            }
        }
    }

    private static let plistName = "dev.sunnyday.lsvpncompanion.helper.plist"
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "helper-install")

    private var service: SMAppService { .daemon(plistName: Self.plistName) }

    var status: Status {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try service.register()
        logger.log("helper зарегистрирован, статус: \(String(describing: service.status), privacy: .public)")
    }

    func unregister() async throws {
        try await service.unregister()
    }

    /// Обновление регистрации после смены подписи приложения.
    ///
    /// launchd хранит launch constraint (LWCR), снятый при регистрации, и после
    /// пересборки отказывается запускать демон (`EX_CONFIG`, `needs LWCR
    /// update`). Обновляет job именно повторный `register()` — снятие
    /// регистрации перед ним оставляет запись со старым constraint.
    /// Полный цикл `unregister` → `register` остаётся запасным вариантом.
    ///
    /// `unregister()` завершается асинхронно: если сразу вызвать `register()`,
    /// снятие регистрации отменит её, и демон останется незарегистрированным
    /// вовсе. Поэтому ждём фактического `.notRegistered`.
    func reinstall() async throws {
        if service.status != .notRegistered {
            do {
                try service.register()
                logger.log("регистрация helper обновлена без снятия")
                return
            } catch {
                logger.log("""
                    повторная регистрация не прошла \
                    (\(String(describing: error), privacy: .public)) — снимаем и ставим заново
                    """)
            }
            try? await service.unregister()
            await waitForUnregistration()
        }
        try service.register()
    }

    private func waitForUnregistration() async {
        for _ in 0..<30 {
            if service.status == .notRegistered { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        logger.error("helper не снялся с регистрации за 3 с — регистрируем поверх")
    }

    /// Открыть раздел Системных настроек, где helper одобряют.
    @MainActor
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Версия helper, лежащего в бандле приложения. Если работающий демон
    /// сообщает другую — launchd держит в памяти устаревший бинарь, и его надо
    /// переустановить.
    var bundledHelperVersion: String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(HelperConstants.helperExecutableName)
            .path
        return HelperConstants.version(ofExecutableAt: path)
    }
}
