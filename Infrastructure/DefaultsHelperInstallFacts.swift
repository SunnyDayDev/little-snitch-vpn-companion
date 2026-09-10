import Foundation

/// Факт «helper удалён пользователем» в `UserDefaults` приложения — рядом с
/// отметками онбординга, а не в `AppSettings`: это решение-действие, а не
/// предпочтение, и тумблера в интерфейсе у него нет. Без этого флага
/// авто-восстановление вернуло бы демон при следующем запуске.
/// `UserDefaults` не помечен Sendable, но потокобезопасен по документации
/// Apple — отсюда `@unchecked`.
struct DefaultsHelperInstallFacts: HelperInstallFacts, @unchecked Sendable {
    static let removedByUserKey = "helperRemovedByUser"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var removedByUser: Bool {
        defaults.bool(forKey: Self.removedByUserKey)
    }

    func setRemovedByUser(_ value: Bool) {
        defaults.set(value, forKey: Self.removedByUserKey)
    }
}
