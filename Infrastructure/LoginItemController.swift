import Foundation
import ServiceManagement
import os

/// Автозапуск приложения (ФТ-8) через `SMAppService.mainApp`.
struct LoginItemController: Sendable {
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "login-item")

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("не удалось изменить автозапуск: \(String(describing: error), privacy: .public)")
        }
    }
}
