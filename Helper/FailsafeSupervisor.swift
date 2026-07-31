import Foundation

/// Одноразовый таймер супервизии за абстракцией: боевой —
/// `DispatchSourceTimer`, в тестах — ручной фейк. Повторный `schedule`
/// заменяет предыдущий.
protocol FailsafeTimer: Sendable {
    func schedule(after seconds: Double, handler: @escaping @Sendable () -> Void)
    func cancel()
}

final class DispatchFailsafeTimer: FailsafeTimer, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "\(HelperConstants.machServiceName).failsafe")
    private var source: DispatchSourceTimer?

    func schedule(after seconds: Double, handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: handler)
        timer.resume()
        source = timer
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
    }
}

/// Dead-man's switch (D5): считает живые XPC-соединения приложения. Ноль
/// клиентов при активном строгом режиме взводит таймер таймаута супервизии,
/// по срабатыванию — `closeGroups` для групп конфига. Новое соединение или
/// деактивация конфига отменяют таймер. При неактивном строгом режиме тип
/// только ведёт счётчик — поведение helper неотличимо от версии без failsafe.
final class FailsafeSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var config: FailsafeConfig
    private var liveClients = 0
    private let timer: any FailsafeTimer
    private let closeGroups: @Sendable ([String]) -> Void

    init(config: FailsafeConfig,
         timer: any FailsafeTimer,
         closeGroups: @escaping @Sendable ([String]) -> Void) {
        self.config = config
        self.timer = timer
        self.closeGroups = closeGroups
    }

    /// Новый конфиг от приложения. Деактивация отменяет взведённый таймер —
    /// в том числе штатно перед переустановкой helper (порядок D5:
    /// `strictActive=false` раньше дерегистрации).
    func apply(_ config: FailsafeConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
        if !config.strictActive {
            timer.cancel()
        }
    }

    func clientConnected() {
        lock.lock()
        liveClients += 1
        lock.unlock()
        timer.cancel()
    }

    func clientDisconnected() {
        lock.lock()
        // Клампим на нуле: неожиданный повтор invalidation не должен увести
        // счётчик в минус и сломать арифметику живых клиентов.
        liveClients = max(0, liveClients - 1)
        let arm = liveClients == 0 && config.strictActive
        let timeout = config.supervisionTimeoutSeconds
        lock.unlock()
        guard arm else { return }
        timer.schedule(after: timeout) { [weak self] in self?.timerFired() }
    }

    private func timerFired() {
        lock.lock()
        // Перепроверка в момент срабатывания: cancel мог проиграть гонку уже
        // сработавшему таймеру — реконнект или деактивация обязаны победить.
        guard liveClients == 0, config.strictActive else {
            lock.unlock()
            return
        }
        let groups = config.groups
        lock.unlock()
        closeGroups(groups)
    }
}
