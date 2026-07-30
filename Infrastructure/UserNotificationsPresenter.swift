import Foundation
import UserNotifications
import os

/// Уведомления через Notification Center (ФТ-5). Категории («утечка и
/// восстановление» / «ошибки») фильтруются до вызова — здесь только доставка.
///
/// Каждый отказ доставки попадает в журнал: молчащие уведомления во время
/// утечки неотличимы от «всё хорошо», и без записи причину не найти.
struct UserNotificationsPresenter: NotificationPresenting {
    let journal: any JournalStore
    let clock: any Clock

    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "notifications")

    enum Authorization: String, Sendable {
        case notRequested, granted, denied, provisional

        var isUsable: Bool { self == .granted || self == .provisional }

        var description: String {
            switch self {
            case .notRequested: "не запрошены"
            case .granted: "разрешены"
            case .denied: "запрещены в Системных настройках"
            case .provisional: "разрешены тихо"
            }
        }
    }

    func authorization() async -> Authorization {
        switch await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus {
        case .authorized: .granted
        case .provisional: .provisional
        case .denied: .denied
        default: .notRequested
        }
    }

    /// Спрашивает разрешение, если его ещё не спрашивали. Без этого уведомления
    /// молча не доставляются — именно так и вышло: онбординг закрыли, шаг с
    /// разрешением остался не пройден.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Authorization {
        let current = await authorization()
        guard current == .notRequested else { return current }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func present(_ notification: AppNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.category == .transition ? .default : nil
        content.interruptionLevel = notification.category == .transition ? .timeSensitive : .active

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("уведомление не доставлено: \(String(describing: error), privacy: .public)")
            await journal.append(JournalEvent(
                time: await clock.now(),
                kind: .error("уведомление «\(notification.title)» не доставлено: "
                    + "\(error.localizedDescription)")))
        }
    }
}
