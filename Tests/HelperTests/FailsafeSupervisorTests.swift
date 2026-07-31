import Foundation
import Testing

/// Ручной таймер: `fire()` намеренно срабатывает и после `cancel` — так
/// моделируется гонка «боевой таймер сработал одновременно с отменой», и
/// супервизор обязан перепроверять условия в момент срабатывания.
private final class FakeFailsafeTimer: FailsafeTimer, @unchecked Sendable {
    private(set) var scheduledAfter: Double?
    private(set) var cancelCount = 0
    private var handler: (@Sendable () -> Void)?

    func schedule(after seconds: Double, handler: @escaping @Sendable () -> Void) {
        scheduledAfter = seconds
        self.handler = handler
    }

    func cancel() {
        cancelCount += 1
        scheduledAfter = nil
    }

    func fire() {
        handler?()
    }
}

@Suite("Dead-man's switch helper")
struct FailsafeSupervisorTests {
    private final class ClosedGroups: @unchecked Sendable {
        var calls: [[String]] = []
    }

    private func makeSupervisor(config: FailsafeConfig)
        -> (FailsafeSupervisor, FakeFailsafeTimer, ClosedGroups) {
        let timer = FakeFailsafeTimer()
        let closed = ClosedGroups()
        let supervisor = FailsafeSupervisor(config: config, timer: timer) { groups in
            closed.calls.append(groups)
        }
        return (supervisor, timer, closed)
    }

    @Test("Крэш: последний клиент пропал → таймер таймаута → закрытие групп")
    func crashClosesGroups() {
        let (supervisor, timer, closed) = makeSupervisor(config: FailsafeConfig(
            strictActive: true, groups: ["VPN down"], supervisionTimeoutSeconds: 30))
        supervisor.clientConnected()
        supervisor.clientDisconnected()
        #expect(timer.scheduledAfter == 30)
        timer.fire()
        #expect(closed.calls == [["VPN down"]])
    }

    @Test("Быстрый реконнект: новое соединение отменяет таймер")
    func reconnectCancelsTimer() {
        let (supervisor, timer, closed) = makeSupervisor(config: FailsafeConfig(
            strictActive: true, groups: ["VPN down"]))
        supervisor.clientConnected()
        supervisor.clientDisconnected()
        #expect(timer.scheduledAfter != nil)
        supervisor.clientConnected()
        #expect(timer.scheduledAfter == nil)
        // Гонка: таймер успел сработать одновременно с отменой —
        // клиент жив, группы не трогаются.
        timer.fire()
        #expect(closed.calls.isEmpty)
    }

    @Test("Неактивный конфиг: пропажа клиентов не взводит таймер")
    func inactiveConfigDoesNothing() {
        let (supervisor, timer, closed) = makeSupervisor(config: .inactive)
        supervisor.clientConnected()
        supervisor.clientDisconnected()
        #expect(timer.scheduledAfter == nil)
        timer.fire()
        #expect(closed.calls.isEmpty)
    }

    @Test("Деактивация конфига отменяет взведённый таймер")
    func deactivationCancelsArmedTimer() {
        let (supervisor, timer, closed) = makeSupervisor(config: FailsafeConfig(
            strictActive: true, groups: ["VPN down"]))
        supervisor.clientConnected()
        supervisor.clientDisconnected()
        #expect(timer.scheduledAfter != nil)
        supervisor.apply(.inactive)
        #expect(timer.scheduledAfter == nil)
        timer.fire()
        #expect(closed.calls.isEmpty)
    }

    @Test("Второй живой клиент удерживает таймер невзведённым")
    func secondClientKeepsTimerDisarmed() {
        let (supervisor, timer, closed) = makeSupervisor(config: FailsafeConfig(
            strictActive: true, groups: ["VPN down"]))
        supervisor.clientConnected()
        supervisor.clientConnected()
        supervisor.clientDisconnected()
        #expect(timer.scheduledAfter == nil)
        timer.fire()
        #expect(closed.calls.isEmpty)
    }

    @Test("Закрываются группы конфига на момент срабатывания")
    func closesGroupsFromLatestConfig() {
        let (supervisor, timer, closed) = makeSupervisor(config: FailsafeConfig(
            strictActive: true, groups: ["VPN down"]))
        supervisor.clientConnected()
        supervisor.apply(FailsafeConfig(strictActive: true,
                                        groups: ["VPN down", "Блок рекламы"]))
        supervisor.clientDisconnected()
        timer.fire()
        #expect(closed.calls == [["VPN down", "Блок рекламы"]])
    }
}
