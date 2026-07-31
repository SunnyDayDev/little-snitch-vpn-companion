import Foundation

/// Failsafe-конфигурация helper (D5 design): активность строгого режима,
/// список групп и таймаут супервизии. По XPC ездит как JSON (`Data` —
/// XPC-дружелюбный транспорт), helper персистит её на диск в том же формате.
/// Файл компилируется и в приложение, и в helper.
struct FailsafeConfig: Hashable, Codable, Sendable {
    /// Дефолт — рабочая гипотеза design.md: сильно больше времени
    /// переустановки presence-соединения, чтобы исключить ложные срабатывания.
    static let defaultSupervisionTimeoutSeconds = 15.0

    var strictActive: Bool
    var groups: [String]
    var supervisionTimeoutSeconds: Double

    init(strictActive: Bool,
         groups: [String],
         supervisionTimeoutSeconds: Double = Self.defaultSupervisionTimeoutSeconds) {
        self.strictActive = strictActive
        self.groups = groups
        self.supervisionTimeoutSeconds = supervisionTimeoutSeconds
    }

    /// Отсутствие таймаута в JSON — не повод терять конфиг: файл от старой
    /// версии приложения читается с дефолтом.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strictActive = try container.decode(Bool.self, forKey: .strictActive)
        groups = try container.decode([String].self, forKey: .groups)
        supervisionTimeoutSeconds = try container
            .decodeIfPresent(Double.self, forKey: .supervisionTimeoutSeconds)
            ?? Self.defaultSupervisionTimeoutSeconds
    }

    /// Неактивный failsafe: helper обязан вести себя байт-в-байт как версия
    /// без failsafe вовсе.
    static let inactive = FailsafeConfig(strictActive: false, groups: [])
}

/// Эшелон 4 (§10.2): закрывать ли группы при старте демона. Только при
/// активном строгом режиме и только в первые минуты после загрузки ОС —
/// перезапуск демона посреди сессии (переустановка) не должен закрывать
/// поверх живого приложения со свежим Protected-вердиктом.
enum BootClosePolicy {
    /// Спайк 5.1: helper с RunAtLoad стартует при uptime ~40 с; пять минут
    /// покрывают и медленную загрузку, и FileVault-паузу до логина.
    static let uptimeThresholdSeconds: Double = 300

    static func shouldClose(config: FailsafeConfig, uptimeSeconds: Double) -> Bool {
        config.strictActive && !config.groups.isEmpty
            && uptimeSeconds < uptimeThresholdSeconds
    }
}
