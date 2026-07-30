/// Фейки портов: ни один тест Application-слоя не трогает сеть, диск,
/// уведомления и helper.

actor FakeBeacon: BeaconProbing {
    private var queued: [BeaconFetch] = []
    private var fallback: BeaconFetch = .offline(.timeout)
    private(set) var callCount = 0

    init() {}

    func enqueue(_ fetches: BeaconFetch...) {
        queued.append(contentsOf: fetches)
    }

    func setFallback(_ fetch: BeaconFetch) {
        fallback = fetch
    }

    func fetchTrace(timeout: Double) async -> BeaconFetch {
        callCount += 1
        return queued.isEmpty ? fallback : queued.removeFirst()
    }
}

actor FakeDirectIP: DirectIPProbing {
    private var answers: [IPAddress?] = []
    private var fallback: IPAddress?
    private(set) var callCount = 0

    init(fallback: IPAddress? = nil) {
        self.fallback = fallback
    }

    func enqueue(_ values: IPAddress?...) {
        answers.append(contentsOf: values)
    }

    func fetchDirectIP(timeout: Double) async -> IPAddress? {
        callCount += 1
        return answers.isEmpty ? fallback : answers.removeFirst()
    }
}

actor FakeTripwire: TripwireMonitoring {
    private(set) var isStarted = false
    private(set) var heartbeatSeconds: Double?
    private var onBreak: (@Sendable () -> Void)?

    init() {}

    func start(heartbeatSeconds: Double, onBreak: @escaping @Sendable () -> Void) async {
        isStarted = true
        self.heartbeatSeconds = heartbeatSeconds
        self.onBreak = onBreak
    }

    func stop() async {
        isStarted = false
    }

    func simulateBreak() {
        onBreak?()
    }
}

actor FakePathMonitor: PathMonitoring {
    private(set) var isStarted = false
    private var onChange: (@Sendable (NetworkPathInfo) -> Void)?

    init() {}

    func start(onChange: @escaping @Sendable (NetworkPathInfo) -> Void) async {
        isStarted = true
        self.onChange = onChange
    }

    func stop() async {
        isStarted = false
    }

    func simulateChange(_ info: NetworkPathInfo) {
        onChange?(info)
    }
}

actor FakeRuleGroupGateway: RuleGroupGateway {
    private(set) var groups: [String: Bool]
    private(set) var operations: [RuleGroupOperation] = []
    private(set) var listCallCount = 0
    private var listError: RuleGroupGatewayError?
    private var setError: RuleGroupGatewayError?

    init(groups: [String: Bool] = [:]) {
        self.groups = groups
    }

    func failList(with error: RuleGroupGatewayError?) { listError = error }
    func failSet(with error: RuleGroupGatewayError?) { setError = error }

    func helperVersion() async throws -> String { "1.0" }

    func listRuleGroups() async throws -> [RuleGroup] {
        listCallCount += 1
        if let listError { throw listError }
        return groups.map { RuleGroup(name: $0.key, enabled: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func setRuleGroup(_ name: String, enabled: Bool) async throws {
        if let setError { throw setError }
        operations.append(RuleGroupOperation(name: name, enable: enabled))
        groups[name] = enabled
    }

    func resetOperations() {
        operations.removeAll()
        listCallCount = 0
    }
}

actor FakeWifi: WifiPowerGateway {
    private(set) var turnedOffCount = 0
    private var error: (any Error)?

    init() {}

    func failNext(_ error: (any Error)?) { self.error = error }

    func turnWifiOff() async throws {
        if let error { throw error }
        turnedOffCount += 1
    }
}

actor FakeNotifications: NotificationPresenting {
    private(set) var presented: [AppNotification] = []

    init() {}

    func present(_ notification: AppNotification) async {
        presented.append(notification)
    }
}

actor FakeJournal: JournalStore {
    private(set) var events: [JournalEvent] = []

    init() {}

    func append(_ event: JournalEvent) async { events.append(event) }
    func recent(limit: Int) async -> [JournalEvent] { Array(events.suffix(limit)) }
    func clear() async { events.removeAll() }
}

/// Часы без задержек: короткие сны (debounce, подтверждение утечки) проходят
/// мгновенно, а длинные — интервалы фоновых петель — подвешиваются навсегда.
/// Так петли стоят на месте, вместо того чтобы крутиться без задержки и
/// заваливать фейки пробами.
actor ImmediateClock: Clock {
    private(set) var current: Instant
    private(set) var sleeps: [Double] = []
    private let parkThreshold: Double

    init(start: Double = 0, parkThreshold: Double = 10) {
        current = Instant(secondsSinceEpoch: start)
        self.parkThreshold = parkThreshold
    }

    func now() -> Instant { current }

    func sleep(seconds: Double) async {
        sleeps.append(seconds)
        guard seconds < parkThreshold else {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return
        }
        current = current.adding(seconds: seconds)
    }
}

/// Часы с ручным управлением: `sleep` подвешивает вызывающего до `advance`.
/// Нужны там, где важна одновременность (debounce событий пути).
actor ManualClock: Clock {
    private struct Waiter {
        let deadline: Double
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var current: Instant
    private var waiters: [Waiter] = []

    init(start: Double = 0) {
        current = Instant(secondsSinceEpoch: start)
    }

    var sleeperCount: Int { waiters.count }

    func now() -> Instant { current }

    func sleep(seconds: Double) async {
        let deadline = current.secondsSinceEpoch + seconds
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(deadline: deadline, continuation: continuation))
        }
    }

    func advance(by seconds: Double) {
        current = current.adding(seconds: seconds)
        let due = waiters.filter { $0.deadline <= current.secondsSinceEpoch }
        waiters.removeAll { $0.deadline <= current.secondsSinceEpoch }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Ждёт, пока в часах не окажется нужное число спящих.
    func waitForSleepers(_ count: Int) async {
        while waiters.count < count {
            await Task.yield()
        }
    }
}

// MARK: - Хелперы тестовых данных

enum TestData {
    static let cloudflareIP = IPAddress("2a09:bac5:4c9c:18f8::3f")!
    static let foreignIP = IPAddress("203.0.113.40")!
    static let serverIP = IPAddress("198.51.100.10")!
    static let providerIP = IPAddress("192.0.2.30")!

    static let protectedBody = """
        ip=2a09:bac5:4c9c:18f8::3f
        warp=on
        colo=AMS
        loc=NL
        """

    static let leakBody = """
        ip=203.0.113.40
        warp=off
        colo=DME
        loc=RU
        """

    static func settings(leakGroups: [String] = ["VPN down"]) -> AppSettings {
        var settings = AppSettings()
        settings.leakGroups = leakGroups
        settings.forbiddenEgressIPs = ["198.51.100.10"]
        return settings
    }
}
