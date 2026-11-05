/// Сервер живёт с приложением, независимо от сетевых слоёв мониторинга.
protocol StatusServing: Sendable {
    func start() throws
    func stop()
}

actor StatusServiceLifecycle {
    private let server: any StatusServing
    private let journal: any JournalStore
    private let clock: any Clock
    private var started = false
    private var stopped = false

    init(server: any StatusServing, journal: any JournalStore, clock: any Clock) {
        self.server = server; self.journal = journal; self.clock = clock
    }
    func start() async {
        guard !started, !stopped else { return }
        started = true
        do { try server.start() }
        catch {
            await journal.append(JournalEvent(time: await clock.now(),
                kind: .warning("CLI статуса недоступен: не удалось запустить локальный сервер")))
        }
    }
    func stop() {
        stopped = true
        server.stop()
    }
}
