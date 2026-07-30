import Foundation
import os

/// Настройки в `UserDefaults` (ФТ-7). Каждая настройка — отдельный ключ, а не
/// один блоб: так их можно править через `defaults write`, включая скрытые
/// debug-рычаги для приёмки (§14 SPEC.md).
/// `UserDefaults` не помечен Sendable, но потокобезопасен по документации
/// Apple — отсюда `@unchecked`.
struct DefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    enum Key: String, CaseIterable {
        case launchAtLogin, monitoringEnabled, observeOnly, escalationEnabled
        case notifyTransitions, notifyErrors
        case heartbeatSeconds, probeSeconds, probeTimeoutSeconds
        case leakConfirmationSeconds, pathDebounceSeconds
        case expectedIPs, leakGroups, forbiddenEgressIPs
        case ruBeaconURL, ruBeaconFallbackURL, ruBeaconRefreshSeconds
        case debugIgnoreWarp, debugFakeEgressIP
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "settings")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    /// Дефолты §13 SPEC.md. `leakGroups` намеренно пуст: имя группы
    /// подставляется онбордингом, только если она реально есть в LS.
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
            Key.expectedIPs.rawValue: fallback.expectedIPs,
            Key.leakGroups.rawValue: fallback.leakGroups,
            Key.forbiddenEgressIPs.rawValue: fallback.forbiddenEgressIPs,
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

        settings.expectedIPs = defaults.stringArray(forKey: Key.expectedIPs.rawValue) ?? []
        settings.leakGroups = defaults.stringArray(forKey: Key.leakGroups.rawValue) ?? []
        settings.forbiddenEgressIPs = defaults.stringArray(forKey: Key.forbiddenEgressIPs.rawValue) ?? []

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

        defaults.set(settings.expectedIPs, forKey: Key.expectedIPs.rawValue)
        defaults.set(settings.leakGroups, forKey: Key.leakGroups.rawValue)
        defaults.set(settings.forbiddenEgressIPs, forKey: Key.forbiddenEgressIPs.rawValue)

        defaults.set(settings.ruBeaconURL, forKey: Key.ruBeaconURL.rawValue)
        defaults.set(settings.ruBeaconFallbackURL, forKey: Key.ruBeaconFallbackURL.rawValue)
        defaults.set(settings.ruBeaconRefreshSeconds, forKey: Key.ruBeaconRefreshSeconds.rawValue)
    }

    /// Защита от значений, которые превратят детектор в генератор трафика
    /// или, наоборот, в спящего сторожа.
    static func sanitized(_ settings: AppSettings) -> AppSettings {
        var settings = settings
        settings.heartbeatSeconds = settings.heartbeatSeconds.clamped(to: 5...600)
        settings.probeSeconds = settings.probeSeconds.clamped(to: 10...3600)
        settings.probeTimeoutSeconds = settings.probeTimeoutSeconds.clamped(to: 1...30)
        settings.leakConfirmationSeconds = settings.leakConfirmationSeconds.clamped(to: 1...10)
        settings.pathDebounceSeconds = settings.pathDebounceSeconds.clamped(to: 0.05...5)
        settings.ruBeaconRefreshSeconds = settings.ruBeaconRefreshSeconds.clamped(to: 30...86_400)
        return settings
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard self.isFinite, self > 0 else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
