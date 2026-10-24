import Foundation
import os

/// Итог подготовки массива детекторов при запуске: что писать в журнал.
enum DetectorsLoadOutcome: Hashable, Sendable {
    /// Ключ `detectors` есть и читается.
    case stored
    /// Ключа не было, старые ключи одного детектора собраны в «Основной».
    case migrated(DetectorConfig)
    /// Ключа не было, старых ключей тоже — чистая установка.
    case freshInstall
    /// Ключ есть, но не читается: работает детектор по умолчанию, значение
    /// не перезаписывается до первого изменения настроек.
    case corrupted(String)
}

/// Настройки в `UserDefaults` (ФТ-7). Общие настройки — отдельные ключи, их
/// можно править через `defaults write`, включая скрытые debug-рычаги для
/// приёмки (§14 SPEC.md). Детекторы — один ключ `detectors` с JSON-массивом
/// (D10 design.md): отдельные ключи на детектор не нужны.
/// `UserDefaults` не помечен Sendable, но потокобезопасен по документации
/// Apple — отсюда `@unchecked`.
struct DefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    enum Key: String, CaseIterable {
        case launchAtLogin, monitoringEnabled, observeOnly, escalationEnabled
        case notifyTransitions, notifyErrors
        case heartbeatSeconds, probeSeconds, probeTimeoutSeconds
        case leakConfirmationSeconds, pathDebounceSeconds
        case detectors
        case ruBeaconURL, ruBeaconFallbackURL, ruBeaconRefreshSeconds
        case debugIgnoreWarp, debugFakeEgressIP
    }

    /// Ключи версии с одним детектором: только источник миграции. После неё
    /// не читаются и не перезаписываются — откат на прежнюю версию читает
    /// прежние значения.
    enum LegacyKey: String, CaseIterable {
        case protectionMode, expectedIPs, leakGroups, forbiddenEgressIPs
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "settings")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    /// Дефолты §13 SPEC.md. Детекторов в регистрации нет намеренно:
    /// отсутствие ключа `detectors` — признак миграции.
    private func registerDefaults() {
        let fallback = AppSettings()
        defaults.register(defaults: [
            Key.launchAtLogin.rawValue: fallback.launchAtLogin,
            Key.monitoringEnabled.rawValue: fallback.monitoringEnabled,
            Key.observeOnly.rawValue: fallback.observeOnly,
            Key.escalationEnabled.rawValue: fallback.escalationEnabled,
            Key.notifyTransitions.rawValue: fallback.notifyTransitions,
            Key.notifyErrors.rawValue: fallback.notifyErrors,
            Key.heartbeatSeconds.rawValue: fallback.heartbeatSeconds,
            Key.probeSeconds.rawValue: fallback.probeSeconds,
            Key.probeTimeoutSeconds.rawValue: fallback.probeTimeoutSeconds,
            Key.leakConfirmationSeconds.rawValue: fallback.leakConfirmationSeconds,
            Key.pathDebounceSeconds.rawValue: fallback.pathDebounceSeconds,
            Key.ruBeaconURL.rawValue: fallback.ruBeaconURL,
            Key.ruBeaconFallbackURL.rawValue: fallback.ruBeaconFallbackURL,
            Key.ruBeaconRefreshSeconds.rawValue: fallback.ruBeaconRefreshSeconds,
            Key.debugIgnoreWarp.rawValue: fallback.debugIgnoreWarp,
        ])
    }

    func load() -> AppSettings {
        var settings = AppSettings()
        settings.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin.rawValue)
        settings.monitoringEnabled = defaults.bool(forKey: Key.monitoringEnabled.rawValue)
        settings.observeOnly = defaults.bool(forKey: Key.observeOnly.rawValue)
        settings.escalationEnabled = defaults.bool(forKey: Key.escalationEnabled.rawValue)
        settings.notifyTransitions = defaults.bool(forKey: Key.notifyTransitions.rawValue)
        settings.notifyErrors = defaults.bool(forKey: Key.notifyErrors.rawValue)

        settings.heartbeatSeconds = defaults.double(forKey: Key.heartbeatSeconds.rawValue)
        settings.probeSeconds = defaults.double(forKey: Key.probeSeconds.rawValue)
        settings.probeTimeoutSeconds = defaults.double(forKey: Key.probeTimeoutSeconds.rawValue)
        settings.leakConfirmationSeconds = defaults.double(forKey: Key.leakConfirmationSeconds.rawValue)
        settings.pathDebounceSeconds = defaults.double(forKey: Key.pathDebounceSeconds.rawValue)

        settings.detectors = readDetectors().detectors

        settings.ruBeaconURL = defaults.string(forKey: Key.ruBeaconURL.rawValue)
            ?? AppSettings().ruBeaconURL
        settings.ruBeaconFallbackURL = defaults.string(forKey: Key.ruBeaconFallbackURL.rawValue)
            ?? AppSettings().ruBeaconFallbackURL
        settings.ruBeaconRefreshSeconds = defaults.double(forKey: Key.ruBeaconRefreshSeconds.rawValue)

        settings.debugIgnoreWarp = defaults.bool(forKey: Key.debugIgnoreWarp.rawValue)
        settings.debugFakeEgressIP = defaults.string(forKey: Key.debugFakeEgressIP.rawValue)

        return Self.sanitized(settings)
    }

    func save(_ settings: AppSettings) {
        let settings = Self.sanitized(settings)
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin.rawValue)
        defaults.set(settings.monitoringEnabled, forKey: Key.monitoringEnabled.rawValue)
        defaults.set(settings.observeOnly, forKey: Key.observeOnly.rawValue)
        defaults.set(settings.escalationEnabled, forKey: Key.escalationEnabled.rawValue)
        defaults.set(settings.notifyTransitions, forKey: Key.notifyTransitions.rawValue)
        defaults.set(settings.notifyErrors, forKey: Key.notifyErrors.rawValue)

        defaults.set(settings.heartbeatSeconds, forKey: Key.heartbeatSeconds.rawValue)
        defaults.set(settings.probeSeconds, forKey: Key.probeSeconds.rawValue)
        defaults.set(settings.probeTimeoutSeconds, forKey: Key.probeTimeoutSeconds.rawValue)
        defaults.set(settings.leakConfirmationSeconds, forKey: Key.leakConfirmationSeconds.rawValue)
        defaults.set(settings.pathDebounceSeconds, forKey: Key.pathDebounceSeconds.rawValue)

        writeDetectors(settings.detectors)

        defaults.set(settings.ruBeaconURL, forKey: Key.ruBeaconURL.rawValue)
        defaults.set(settings.ruBeaconFallbackURL, forKey: Key.ruBeaconFallbackURL.rawValue)
        defaults.set(settings.ruBeaconRefreshSeconds, forKey: Key.ruBeaconRefreshSeconds.rawValue)
    }

    // MARK: - Детекторы

    /// Один раз при запуске: миграция пишет собранный «Основной» в defaults,
    /// остальные исходы только сообщаются. Повреждённое значение не
    /// трогается — его перезапишет первое изменение настроек.
    @discardableResult
    func prepareDetectors() -> DetectorsLoadOutcome {
        let (detectors, outcome) = readDetectors()
        if case .migrated = outcome {
            writeDetectors(detectors)
            logger.info("настройки одного детектора перенесены в «Основной»")
        }
        if case .corrupted(let reason) = outcome {
            logger.error("массив детекторов не читается: \(reason, privacy: .public)")
        }
        return outcome
    }

    /// Чтение без побочных эффектов: до `prepareDetectors()` миграция
    /// собирается в памяти так же, как запишется.
    private func readDetectors() -> (detectors: [DetectorConfig], outcome: DetectorsLoadOutcome) {
        guard let raw = defaults.object(forKey: Key.detectors.rawValue) else {
            guard let migrated = migratedPrimary() else {
                return ([.primary()], .freshInstall)
            }
            return ([migrated], .migrated(migrated))
        }
        guard let text = raw as? String, let data = text.data(using: .utf8) else {
            return ([.primary()], .corrupted("значение ключа «detectors» — не JSON-строка"))
        }
        do {
            return (try JSONDecoder().decode([DetectorConfig].self, from: data), .stored)
        } catch {
            return ([.primary()], .corrupted(String(describing: error)))
        }
    }

    private func writeDetectors(_ detectors: [DetectorConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(detectors),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("массив детекторов не сериализуется — не записан")
            return
        }
        defaults.set(text, forKey: Key.detectors.rawValue)
    }

    /// «Основной» из ключей версии с одним детектором (§13: без прокси, маяк
    /// Cloudflare, `warp=on` считается защитой, растяжка включена).
    /// `nil` — старых ключей нет: это чистая установка, а не обновление.
    private func migratedPrimary() -> DetectorConfig? {
        let present = LegacyKey.allCases.contains { defaults.object(forKey: $0.rawValue) != nil }
        guard present else { return nil }
        var primary = DetectorConfig.primary()
        // Нераспознанное значение — реактивный режим: безопасный дефолт.
        primary.protectionMode = defaults.string(forKey: LegacyKey.protectionMode.rawValue)
            .flatMap(ProtectionMode.init(rawValue:)) ?? .reactive
        primary.expectedIPs = defaults.stringArray(forKey: LegacyKey.expectedIPs.rawValue) ?? []
        primary.forbiddenEgressIPs = defaults.stringArray(
            forKey: LegacyKey.forbiddenEgressIPs.rawValue) ?? []
        primary.groups = defaults.stringArray(forKey: LegacyKey.leakGroups.rawValue) ?? []
        return primary
    }

    // MARK: - Санитизация

    /// Защита от значений, которые превратят детекторы в генератор трафика
    /// или, наоборот, в спящих сторожей.
    static func sanitized(_ settings: AppSettings) -> AppSettings {
        var settings = settings
        settings.heartbeatSeconds = settings.heartbeatSeconds.clamped(to: 5...600)
        settings.probeSeconds = settings.probeSeconds.clamped(to: 10...3600)
        settings.probeTimeoutSeconds = settings.probeTimeoutSeconds.clamped(to: 1...30)
        settings.leakConfirmationSeconds = settings.leakConfirmationSeconds.clamped(to: 1...10)
        settings.pathDebounceSeconds = settings.pathDebounceSeconds.clamped(to: 0.05...5)
        settings.ruBeaconRefreshSeconds = settings.ruBeaconRefreshSeconds.clamped(to: 30...86_400)

        // Повтор идентификатора (ручная правка JSON) — второй экземпляр
        // отбрасывается: рантаймы детекторов адресуются по нему.
        var seen: Set<DetectorID> = []
        settings.detectors = settings.detectors
            .filter { seen.insert($0.id).inserted }
            .map(sanitized)
        return settings
    }

    static func sanitized(_ detector: DetectorConfig) -> DetectorConfig {
        var detector = detector
        let name = detector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        detector.name = name.isEmpty ? "Без названия" : name
        // Невалидный основной маяк — прежний Cloudflare: проба в никуда
        // молча превратила бы детектор в вечный Offline.
        if !BeaconConfig.isValidURL(detector.beacon.primaryURL) {
            detector.beacon.primaryURL = BeaconConfig.cloudflare.primaryURL
        }
        if let fallback = detector.beacon.fallbackURL, !BeaconConfig.isValidURL(fallback) {
            detector.beacon.fallbackURL = nil
        }
        // Порт вне диапазона зажимается, а не превращает прокси в «напрямую»:
        // детектор с мёртвым прокси уходит в Offline, а прямой путь дал бы
        // egress машины вместо выхода прокси.
        if !detector.proxy.isDirect {
            detector.proxy.port = min(max(detector.proxy.port, 1), 65_535)
        }
        detector.proxy.host = detector.proxy.host.trimmingCharacters(in: .whitespaces)
        return detector
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite, self > 0 else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
