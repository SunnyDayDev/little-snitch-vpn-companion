/// Фейки портов: ни один тест Application-слоя не трогает сеть, диск,
/// уведомления и helper.

import Foundation

/// Мутабельные настройки для тестов «на лету»: провайдер координатора читает
/// актуальное значение при каждом обращении, как боевой DefaultsSettingsStore.
final class SettingsHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings

    init(_ value: AppSettings) { self.value = value }

    var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        value = new
    }
}

actor FakeBeacon: BeaconProbing {
    private var queued: [BeaconFetch] = []
    private var fallback: BeaconFetch = .offline(.timeout)
    private(set) var callCount = 0
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var callObservers: [AsyncStream<Int>.Continuation] = []
    private var holdObservers: [AsyncStream<Void>.Continuation] = []

    init() {}

    func enqueue(_ fetches: BeaconFetch...) {
        queued.append(contentsOf: fetches)
    }

    func setFallback(_ fetch: BeaconFetch) {
        fallback = fetch
    }

    /// Следующая проба подвиснет в полёте до `release()` — для тестов гонок
    /// «проба против пропажи сети».
    func holdNextFetch() { holdNext = true }

    func release() {
        held?.resume()
        held = nil
    }

    /// Поток «ушла проба» (значение — её номер). Подписка оформляется ДО
    /// действия, а результат ждётся через `firstEvent(from:)`: события после
    /// подписки буферизуются и не теряются, а пробы до неё цикл не закрывают.
    func callEvents() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        callObservers.append(continuation)
        return stream
    }

    /// Поток «подвешенная проба фактически встала в полёте».
    func holdEvents() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        holdObservers.append(continuation)
        return stream
    }

    func fetchTrace(timeout: Double) async -> BeaconFetch {
        callCount += 1
        for observer in callObservers { observer.yield(callCount) }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                for observer in holdObservers { observer.yield(()) }
            }
        }
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

actor FakePowerMonitor: PowerMonitoring {
    private(set) var isStarted = false
    private var onWillSleep: (@Sendable () async -> Void)?
    private var onDidWake: (@Sendable () -> Void)?

    init() {}

    func start(onWillSleep: @escaping @Sendable () async -> Void,
               onDidWake: @escaping @Sendable () -> Void) async {
        isStarted = true
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    func stop() async {
        isStarted = false
        onWillSleep = nil
        onDidWake = nil
    }

    /// Возвращается после завершения обработчика — как боевой монитор,
    /// который подтверждает системе сон только по концу закрытия.
    func simulateWillSleep() async {
        await onWillSleep?()
    }

    func simulateDidWake() async {
        onDidWake?()
    }
}

actor FakeRuleGroupGateway: RuleGroupGateway {
    private(set) var groups: [String: Bool]
    private(set) var operations: [RuleGroupOperation] = []
    private(set) var listCallCount = 0
    private var listError: RuleGroupGatewayError?
    private var setError: RuleGroupGatewayError?
    /// Список «как есть» — с видом групп и повторами имён; словарь `groups`
    /// такого выразить не может.
    private var listOverride: [RuleGroup]?

    init(groups: [String: Bool] = [:]) {
        self.groups = groups
    }

    /// Версия helper по сценарию: молчит до K-го вызова или до условия
    /// (например, «после полного цикла»), отвечает заданной строкой.
    private var versionProvider: @Sendable () -> String = { "1.0" }
    private var versionAnswers: @Sendable (Int) -> Bool = { _ in true }
    private(set) var versionCallCount = 0
    private(set) var resetConnectionCount = 0

    func failList(with error: RuleGroupGatewayError?) { listError = error }
    func failSet(with error: RuleGroupGatewayError?) { setError = error }
    func setList(_ list: [RuleGroup]) { listOverride = list }

    func setVersion(_ version: String) { versionProvider = { version } }
    func setVersionProvider(_ provider: @escaping @Sendable () -> String) {
        versionProvider = provider
    }
    /// Отвечать начиная с вызова номер `call` (считая с единицы).
    func answerVersion(fromCall call: Int) { versionAnswers = { $0 >= call } }
    func answerVersion(when condition: @escaping @Sendable () -> Bool) {
        versionAnswers = { _ in condition() }
    }
    func silenceVersion() { versionAnswers = { _ in false } }

    func helperVersion() async throws -> String {
        versionCallCount += 1
        guard versionAnswers(versionCallCount) else {
            // Текст — как у XPC к незагруженному сервису (журнал 2026-09-09).
            throw RuleGroupGatewayError.helperUnavailable(
                "Connection init failed at lookup with error 3 - No such process")
        }
        return versionProvider()
    }

    func resetConnection() async { resetConnectionCount += 1 }

    func listRuleGroups() async throws -> [RuleGroup] {
        listCallCount += 1
        if let listError { throw listError }
        if let listOverride { return listOverride }
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
    private var sleeperObservers: [AsyncStream<Int>.Continuation] = []

    init(start: Double = 0) {
        current = Instant(secondsSinceEpoch: start)
    }

    var sleeperCount: Int { waiters.count }

    func now() -> Instant { current }

    func sleep(seconds: Double) async {
        let deadline = current.secondsSinceEpoch + seconds
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(deadline: deadline, continuation: continuation))
            for observer in sleeperObservers { observer.yield(waiters.count) }
        }
    }

    func advance(by seconds: Double) {
        current = current.adding(seconds: seconds)
        let due = waiters.filter { $0.deadline <= current.secondsSinceEpoch }
        waiters.removeAll { $0.deadline <= current.secondsSinceEpoch }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Шагнуть ровно к ближайшему дедлайну: интервалы ожидания helper
    /// нарастают, и тесту незачем знать их наизусть.
    func advanceToNextDeadline() {
        guard let next = waiters.map(\.deadline).min() else { return }
        advance(by: max(0, next - current.secondsSinceEpoch))
    }

    /// Ждёт, пока в часах не окажется нужное число спящих — по событию, а не
    /// опросом: `sleep` уведомляет подписчиков в момент постановки спящего.
    func waitForSleepers(_ count: Int) async {
        guard waiters.count < count else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        sleeperObservers.append(continuation)
        defer { continuation.finish() }
        for await sleepers in stream where sleepers >= count { break }
    }
}

// MARK: - Helper

/// Регистратор демона без SMAppService: статус переключается по сценарию.
/// Класс с блокировкой, а не актор: `status` в порте синхронный.
final class FakeHelperRegistrar: HelperRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: HelperRegistrationStatus
    private var bundled: String
    private var registers = 0
    private var unregisters = 0
    private var approvalPrompts = 0
    private var afterRegister: HelperRegistrationStatus = .enabled
    private var afterUnregister: HelperRegistrationStatus = .notRegistered
    private var registerError: (any Error)?
    private var registerFailuresLeft = 0
    private var unregisterError: (any Error)?
    /// `nil` — job есть ровно тогда, когда статус `enabled`; иначе — сценарий
    /// (например, job ещё выгружается после снятия регистрации).
    private var jobLoadedOverride: Bool??
    private(set) var jobProbeCount = 0

    struct TransientError: Error, CustomStringConvertible {
        var description: String { "Operation not permitted" }
    }

    init(status: HelperRegistrationStatus, bundledVersion: String = "1.0") {
        currentStatus = status
        bundled = bundledVersion
    }

    var status: HelperRegistrationStatus { lock.withLock { currentStatus } }
    var bundledVersion: String { lock.withLock { bundled } }
    var registerCount: Int { lock.withLock { registers } }
    var unregisterCount: Int { lock.withLock { unregisters } }
    var approvalPromptCount: Int { lock.withLock { approvalPrompts } }

    func setStatus(_ status: HelperRegistrationStatus) { lock.withLock { currentStatus = status } }
    func setStatusAfterRegister(_ status: HelperRegistrationStatus) { lock.withLock { afterRegister = status } }
    func setStatusAfterUnregister(_ status: HelperRegistrationStatus) { lock.withLock { afterUnregister = status } }
    func failRegister(with error: (any Error)?) { lock.withLock { registerError = error } }
    /// Первые `times` вызовов `register()` падают временной ошибкой.
    func failRegister(times: Int) { lock.withLock { registerFailuresLeft = times } }
    func failUnregister(with error: (any Error)?) { lock.withLock { unregisterError = error } }
    func setJobLoaded(_ value: Bool?) { lock.withLock { jobLoadedOverride = .some(value) } }
    func clearJobLoadedOverride() { lock.withLock { jobLoadedOverride = nil } }

    func register() throws {
        try lock.withLock {
            if let registerError { throw registerError }
            if registerFailuresLeft > 0 {
                registerFailuresLeft -= 1
                throw TransientError()
            }
            registers += 1
            currentStatus = afterRegister
        }
    }

    func isJobLoaded() async -> Bool? {
        lock.withLock {
            jobProbeCount += 1
            if let jobLoadedOverride { return jobLoadedOverride }
            return currentStatus == .enabled
        }
    }

    func unregister() async throws {
        try lock.withLock {
            if let unregisterError { throw unregisterError }
            unregisters += 1
            currentStatus = afterUnregister
        }
    }

    func openApprovalSettings() async {
        lock.withLock { approvalPrompts += 1 }
    }
}

final class FakeHelperInstallFacts: HelperInstallFacts, @unchecked Sendable {
    private let lock = NSLock()
    private var removed: Bool

    init(removedByUser: Bool = false) { removed = removedByUser }

    var removedByUser: Bool { lock.withLock { removed } }
    func setRemovedByUser(_ value: Bool) { lock.withLock { removed = value } }
}

actor FakeFailsafeSync: FailsafeSyncing {
    private(set) var configs: [FailsafeConfig] = []
    private var error: (any Error)?

    init() {}

    func failNext(_ error: (any Error)?) { self.error = error }

    func syncFailsafe(_ config: FailsafeConfig) async throws {
        if let error { throw error }
        configs.append(config)
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

    static func settings(leakGroups: [String] = ["VPN down"],
                         mode: ProtectionMode = .reactive) -> AppSettings {
        var settings = AppSettings()
        settings.leakGroups = leakGroups
        settings.protectionMode = mode
        settings.forbiddenEgressIPs = ["198.51.100.10"]
        return settings
    }
}
