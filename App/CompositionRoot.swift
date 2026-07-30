import Foundation

/// Единственное место, где конкретные реализации инфраструктуры подставляются
/// в порты Application-слоя. Ни один файл Presentation не знает о типах из
/// Infrastructure — только об `AppModel` и use cases.
@MainActor
enum CompositionRoot {
    static func makeModel() -> AppModel {
        let settingsStore = DefaultsSettingsStore()
        let settings = settingsStore.load()

        // Проберы читают настройки в момент запроса: debug-рычаги и адреса
        // РУ-маяка меняются без пересоздания детектора.
        let liveSettings: @Sendable () -> AppSettings = { settingsStore.load() }

        let journal = FileJournalStore()
        let gateway = HelperRuleGroupGateway()
        let notifications = UserNotificationsPresenter(journal: journal, clock: SystemClock())
        let coordinator = MonitoringCoordinator(
            settingsProvider: liveSettings,
            beacon: CloudflareBeaconProber(settingsProvider: liveSettings),
            directIP: RuBeaconProber(settingsProvider: liveSettings),
            tripwire: TripwireConnection(),
            path: SystemPathMonitor(),
            gateway: gateway,
            wifi: NetworksetupWifiGateway(),
            journal: journal,
            notifications: notifications,
            clock: SystemClock())

        return AppModel(coordinator: coordinator,
                        settingsStore: settingsStore,
                        journal: journal,
                        gateway: gateway,
                        notifications: notifications,
                        settings: settings)
    }
}
