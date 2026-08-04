import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// События системного питания (§4.2, слой 4): клиент power management через
/// `IORegisterForSystemPower`. Существует, потому что сон НЕ гасит сеть
/// (TCPKeepAlive держит стек, path unsatisfied не приходит — замер
/// 2026-08-02) и три сетевых слоя детектора засыпание не видят.
///
/// На `kIOMessageSystemWillSleep` система ждёт `IOAllowPowerChange` — этим
/// временем оплачивается закрывающий reconcile строгого режима. Подтверждение
/// уходит ровно один раз на каждое сообщение, по всем веткам: неотправленное
/// стоило бы пользователю системного таймаута (~30 с) на каждом засыпании.
final class SystemPowerMonitor: PowerMonitoring, @unchecked Sendable {
    /// Бюджет на закрытие перед сном — та же логика, что 8 с в
    /// `applicationShouldTerminate`: холодный XPC-вызов helper стоит до 6 с
    /// (таймаут gateway), и бюджет обязан вмещать хотя бы один такой + CLI.
    static let sleepAckBudgetSeconds: Double = 8

    /// Макросы `iokit_common_msg` из IOMessage.h в Swift не импортируются:
    /// sys_iokit (0xE0000000) | sub_iokit_common (0) | номер сообщения.
    static let messageCanSystemSleep: natural_t = 0xE000_0270
    static let messageSystemWillSleep: natural_t = 0xE000_0280
    static let messageSystemHasPoweredOn: natural_t = 0xE000_0300

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.sunnyday.lsvpncompanion.power")
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "power")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var onWillSleep: (@Sendable () async -> Void)?
    private var onDidWake: (@Sendable () -> Void)?

    func start(onWillSleep: @escaping @Sendable () async -> Void,
               onDidWake: @escaping @Sendable () -> Void) async {
        // Повторный start без stop — no-op (как у SystemPathMonitor):
        // resume() после паузы зовёт start при живой подписке.
        let alreadyStarted = lock.withLock {
            guard notifyPort == nil else { return true }
            self.onWillSleep = onWillSleep
            self.onDidWake = onDidWake
            return false
        }
        guard !alreadyStarted else { return }

        // refcon — unmanaged-указатель: объект живёт в CompositionRoot не
        // меньше подписки, а stop() снимает её до любого освобождения.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var port: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let root = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(refcon)
                .takeUnretainedValue()
            monitor.handle(messageType: messageType, argument: argument)
        }, &notifierObject)

        guard root != 0, let port else {
            logger.error("IORegisterForSystemPower не удалась — слой питания не работает")
            lock.withLock {
                self.onWillSleep = nil
                self.onDidWake = nil
            }
            return
        }

        lock.withLock {
            rootPort = root
            notifyPort = port
            notifier = notifierObject
        }
        IONotificationPortSetDispatchQueue(port, queue)
        logger.info("клиент power management зарегистрирован")
    }

    func stop() async {
        let resources: (IONotificationPortRef, io_connect_t, io_object_t)? = lock.withLock {
            guard let port = notifyPort else { return nil }
            let taken = (port, rootPort, notifier)
            notifyPort = nil
            rootPort = 0
            notifier = 0
            onWillSleep = nil
            onDidWake = nil
            return taken
        }
        guard let (port, root, notifierObject) = resources else { return }
        // Строго парная дерегистрация: notifier → соединение → порт.
        var notifierCopy = notifierObject
        IODeregisterForSystemPower(&notifierCopy)
        IOServiceClose(root)
        IONotificationPortDestroy(port)
        logger.info("клиент power management снят")
    }

    // MARK: - Сообщения power management

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.messageCanSystemSleep:
            // Право вето не используем никогда: немедленное безусловное «да».
            logger.debug("kIOMessageCanSystemSleep → разрешаем немедленно")
            acknowledge(token: Int(bitPattern: argument))

        case Self.messageSystemWillSleep:
            willSleep(argument)

        case Self.messageSystemHasPoweredOn:
            logger.info("пробуждение")
            let wake = lock.withLock { onDidWake }
            wake?()

        default:
            break
        }
    }

    /// Гонка «обработчик против бюджета», как в `applicationShouldTerminate`:
    /// подтверждение уходит по первому финишировавшему, ровно один раз.
    /// Единая точка выхода — `acknowledge` после гонки — покрывает и успех,
    /// и ошибку helper (обработчик её глотает), и зависание (бюджет).
    private func willSleep(_ argument: UnsafeMutableRawPointer?) {
        let handler = lock.withLock { onWillSleep }
        let token = Int(bitPattern: argument)
        logger.info("засыпание: закрываем группы, бюджет \(Self.sleepAckBudgetSeconds, privacy: .public) с")

        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await handler?() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(Self.sleepAckBudgetSeconds))
                }
                _ = await group.next()
                group.cancelAll()
            }
            self.acknowledge(token: token)
        }
    }

    private func acknowledge(token: Int) {
        let root = lock.withLock { rootPort }
        guard root != 0 else { return }
        IOAllowPowerChange(root, token)
        logger.info("подтверждение сна отправлено")
    }
}
