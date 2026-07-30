import Foundation
import os

/// Реализация XPC-контракта. Ровно три операции; ничего, кроме них, helper
/// делать не умеет.
final class HelperService: NSObject, HelperProtocol {
    private let cli = LittleSnitchCLI()
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "service")

    private static let executablePath = HelperConstants.currentExecutablePath()
    /// Отпечаток бинаря на момент запуска демона.
    private static let launchedVersion = HelperConstants.version(ofExecutableAt: executablePath)

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(Self.launchedVersion)
        quitIfBinaryChanged()
    }

    /// Самозавершение при смене бинаря не помогает: `SMAppService` привязывает
    /// демон к подписи приложения на момент регистрации, и заменённый бинарь
    /// launchd запускать отказывается (`EX_CONFIG`). Обновление демона делает
    /// приложение — перерегистрацией.
    private func quitIfBinaryChanged() {}

    func listRuleGroups(reply: @escaping @Sendable (Data?, String?) -> Void) {
        defer { quitIfBinaryChanged() }
        do {
            let model = try cli.exportModel()
            let groups = try RuleGroupModelParser.parse(model)
            let encoded = try JSONEncoder().encode(groups)
            logger.debug("отдано \(groups.count, privacy: .public) rule groups")
            reply(encoded, nil)
        } catch {
            let message = String(describing: error)
            logger.error("не удалось получить группы: \(message, privacy: .public)")
            reply(nil, message)
        }
    }

    func setRuleGroup(_ name: String, enabled: Bool,
                      reply: @escaping @Sendable (Bool, String?) -> Void) {
        defer { quitIfBinaryChanged() }
        do {
            try cli.setRuleGroup(name, enabled: enabled)
            logger.log("группа «\(name, privacy: .public)» \(enabled ? "включена" : "выключена", privacy: .public)")
            reply(true, nil)
        } catch {
            let message = String(describing: error)
            logger.error("не удалось переключить группу: \(message, privacy: .public)")
            reply(false, message)
        }
    }
}

/// Делегат listener'а: пускает только клиента, удовлетворяющего
/// code-signing requirement.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement = ClientRequirement.build()
    private let logger = Logger(subsystem: HelperConstants.machServiceName, category: "listener")

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            // Публичный путь проверки клиента (macOS 13+): ядро XPC само
            // сверяет подпись пира с requirement до доставки сообщений.
            try connection.setCodeSigningRequirement(requirement.requirement)
        } catch {
            logger.error("""
                клиент отклонён: requirement \(self.requirement.requirement, privacy: .public) \
                не применён (\(String(describing: error), privacy: .public))
                """)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        logger.debug("клиент принят (strict: \(self.requirement.isStrict, privacy: .public))")
        return true
    }
}
