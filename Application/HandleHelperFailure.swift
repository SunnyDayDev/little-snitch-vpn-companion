/// Эскалация (ФТ-9): утечка подтверждена, а helper или CLI не работают —
/// выключаем Wi-Fi. Единственный случай, когда приложение трогает сеть само.
struct HandleHelperFailure: Sendable {
    enum Outcome: Hashable, Sendable {
        case escalated
        case skippedDisabled
        case skippedObserveOnly
        case skippedNotLeaking
        case failed(String)
    }

    let wifi: any WifiPowerGateway
    let journal: any JournalStore
    let notifications: any NotificationPresenting
    let clock: any Clock

    func run(state: EgressState, settings: AppSettings) async -> Outcome {
        guard state == .leak else { return .skippedNotLeaking }
        guard settings.escalationEnabled else {
            await journalWarning("эскалация выключена настройкой — Wi-Fi не трогаем")
            return .skippedDisabled
        }
        guard !settings.observeOnly else {
            await journalWarning("режим наблюдения — Wi-Fi не трогаем")
            return .skippedObserveOnly
        }

        do {
            try await wifi.turnWifiOff()
            await journal.append(JournalEvent(
                time: await clock.now(),
                kind: .action("эскалация: Wi-Fi выключен"),
                action: "networksetup -setairportpower off"))
            if settings.notifyErrors {
                await notifications.present(AppNotification(
                    category: .error,
                    title: "Wi-Fi выключен",
                    body: "Утечка подтверждена, а Little Snitch недоступен — сеть отключена, чтобы запрещённые приложения не вышли напрямую."))
            }
            return .escalated
        } catch {
            let message = String(describing: error)
            await journal.append(JournalEvent(time: await clock.now(),
                                              kind: .error("эскалация не удалась: \(message)")))
            return .failed(message)
        }
    }

    private func journalWarning(_ text: String) async {
        await journal.append(JournalEvent(time: await clock.now(), kind: .warning(text)))
    }
}
