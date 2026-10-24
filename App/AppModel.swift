import Foundation
import Observation
import SwiftUI

/// Вью-модель поверх use cases: единственный мост между SwiftUI и
/// координатором. Экраны не знают ни о портах, ни об инфраструктуре.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = MonitoringSnapshot()
    private(set) var settings: AppSettings
    private(set) var ruleGroups: [RuleGroup] = []
    /// Зеркало состояния `HelperLifecycle`: экраны читают только его.
    private(set) var helperState: HelperState = .notInstalled
    /// Кнопка, подпись и ссылка строки helper — пересчитываются на каждом
    /// событии актора, в том числе на тиках ожидания (счётчик секунд).
    private(set) var helperPresentation = HelperPresentation.make(
        state: .notInstalled, now: Instant(secondsSinceEpoch: 0))
    private(set) var groupsUpdatedAt: Date?
    private(set) var groupsError: String?
    private(set) var journalEvents: [JournalEvent] = []
    /// Последняя ошибка шлюза — по ней отличаем «helper не одобрен» от
    /// «Little Snitch не пускает свой CLI».
    private(set) var gatewayError: RuleGroupGatewayError?
    /// Состояние разрешения на уведомления — показывается в настройках, чтобы
    /// «тихий» режим не выглядел как «всё спокойно».
    private(set) var notificationAuthorization: UserNotificationsPresenter.Authorization = .notRequested
    var isOnboardingPresented: Bool

    var helperVersion: String? { helperState.runningVersion }

    /// Единый диагноз для поповера и настроек: раньше они показывали разное
    /// («подключён · root» и «недоступен» одновременно), потому что смотрели
    /// в разные источники. Теперь источник один — состояние helper, плюс
    /// ошибка шлюза для случая, когда helper исправен, а Little Snitch не
    /// пускает свой CLI.
    enum Diagnosis: Hashable {
        case ready
        case helper(HelperPresentation)
        case littleSnitchNotAuthorized
        case failing(String)

        var title: String {
            switch self {
            case .ready: "подключён · root"
            case .helper(let presentation): presentation.statusText
            case .littleSnitchNotAuthorized: "Little Snitch не пускает CLI"
            case .failing(let text): text
            }
        }

        var tone: HelperPresentation.Tone {
            switch self {
            case .ready: .ok
            case .helper(let presentation): presentation.tone
            case .littleSnitchNotAuthorized, .failing: .danger
            }
        }

        var isReady: Bool { self == .ready }
    }

    var diagnosis: Diagnosis {
        if let gatewayError, helperState.isResponsive {
            return gatewayError.isLittleSnitchAuthorization
                ? .littleSnitchNotAuthorized
                : .failing(gatewayError.message)
        }
        guard helperState.isReady else { return .helper(helperPresentation) }
        return .ready
    }

    private let coordinator: MonitoringCoordinator
    private let settingsStore: any SettingsStore
    private let journal: FileJournalStore
    private let gateway: HelperRuleGroupGateway
    private let lifecycle: HelperLifecycle
    private let notifications: UserNotificationsPresenter
    private let loginItem = LoginItemController()
    /// Presence-соединение строгого режима (D5): его пропажу helper считает
    /// сигналом dead-man's switch.
    private let presence = HelperPresenceConnection()
    private var observerID: Int?
    private var helperObserver: Task<Void, Never>?
    private var helperTicker: Task<Void, Never>?
    private var helperWatchdog: Task<Void, Never>?
    /// Последний syncFailsafe не дошёл до helper — вотчдог обязан повторить,
    /// иначе устаревший конфиг на диске сработает после выхода приложения.
    private var failsafeSyncPending = false
    /// Итог подготовки детекторов при запуске — записывается в журнал на
    /// старте один раз.
    private var detectorsOutcome: DetectorsLoadOutcome?

    init(coordinator: MonitoringCoordinator,
         settingsStore: any SettingsStore,
         journal: FileJournalStore,
         gateway: HelperRuleGroupGateway,
         lifecycle: HelperLifecycle,
         notifications: UserNotificationsPresenter,
         settings: AppSettings,
         detectorsOutcome: DetectorsLoadOutcome? = nil) {
        self.coordinator = coordinator
        self.settingsStore = settingsStore
        self.journal = journal
        self.gateway = gateway
        self.lifecycle = lifecycle
        self.notifications = notifications
        self.settings = settings
        self.detectorsOutcome = detectorsOutcome
        isOnboardingPresented = !OnboardingState.isCompleted
    }

    // MARK: - Жизненный цикл

    func start() async {
        observerID = await coordinator.observe { [weak self] snapshot in
            Task { @MainActor in self?.snapshot = snapshot }
        }
        await journalDetectorsOutcome()
        if settings.monitoringEnabled {
            await coordinator.start()
        }
        observeHelperState()
        // Старт helper не ждём: после замены бандла ожидание launchd занимает
        // до минуты, а список групп и failsafe подхватит переход в «подключён».
        let lifecycle = self.lifecycle
        Task { await lifecycle.start() }
        await ensureNotificationAuthorization()
        await restoreLoginItemIfLost()
        startHelperWatchdog()
    }

    /// Миграция и повреждение массива детекторов видны в журнале: иначе
    /// пользователь не узнал бы, из чего собран «Основной» и почему его
    /// детекторы пропали.
    private func journalDetectorsOutcome() async {
        guard let outcome = detectorsOutcome else { return }
        detectorsOutcome = nil
        let now = await SystemClock().now()
        switch outcome {
        case .stored, .freshInstall:
            return
        case .migrated(let primary):
            await journal.append(JournalEvent(
                time: now, detector: primary.name,
                kind: .fact("настройки перенесены в детектор «\(primary.name)»: "
                    + "режим \(primary.protectionMode == .strict ? "строгий" : "реактивный"), "
                    + "ожидаемые IP: \(Self.list(primary.expectedIPs)), "
                    + "запрещённые IP: \(Self.list(primary.forbiddenEgressIPs)), "
                    + "группы: \(Self.list(primary.groups)); прежние ключи не тронуты")))
        case .corrupted(let reason):
            await journal.append(JournalEvent(
                time: now,
                kind: .warning("массив детекторов в настройках не читается (\(reason)) — "
                    + "работает детектор «\(DetectorConfig.primaryName)» по умолчанию; "
                    + "значение не перезаписано до первого изменения настроек")))
        }
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "—" : values.joined(separator: ", ")
    }

    /// Синхронизация failsafe-страховки helper (D5): активна только когда
    /// есть включённый строгий детектор и observeOnly его не перекрывает;
    /// группы — объединение групп строгих детекторов. Presence-соединение
    /// держится ровно при активной страховке. Ошибка не фатальна — первый
    /// эшелон (закрытие при выходе) работает и без helper, — но обязана
    /// ретраиться вотчдогом: устаревший strict-конфиг на диске helper иначе
    /// запер бы реактивного пользователя после выхода из приложения.
    /// Пока идёт операция над регистрацией, конфиг не шлём: соединения
    /// рвутся, а актор сам снял супервизию перед циклом.
    private func syncFailsafe() async {
        guard !helperState.isWorking else { return }
        let config = settings.failsafeConfig
        await presence.setActive(config.strictActive)
        guard helperState.isResponsive else {
            failsafeSyncPending = true
            return
        }
        do {
            try await gateway.syncFailsafe(config)
            failsafeSyncPending = false
        } catch {
            // Предупреждаем один раз за эпизод: вотчдог ретраит каждые 20 с,
            // и повторные строки замусорили бы журнал.
            if !failsafeSyncPending {
                let message = (error as? RuleGroupGatewayError)?.message
                    ?? String(describing: error)
                await journal.append(JournalEvent(
                    time: await SystemClock().now(),
                    kind: .warning("failsafe-конфиг не доставлен helper: \(message)")))
            }
            failsafeSyncPending = true
        }
    }

    /// Login item ссылается на конкретный бандл. После переезда приложения
    /// (например из сборочного каталога в `/Applications`) старая запись
    /// указывает не туда, а новая не создаётся — автозапуск молча пропадает.
    private func restoreLoginItemIfLost() async {
        guard settings.launchAtLogin, !loginItem.isEnabled else { return }
        loginItem.setEnabled(true)
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: .warning("автозапуск был потерян (приложение переехало?) — восстановлен")))
    }

    /// Уведомления — половина ценности приложения (ФТ-5), и их отсутствие
    /// незаметно: система молча отбрасывает запросы, если разрешение не
    /// запрашивали. Спрашиваем при запуске и пишем итог в журнал.
    private func ensureNotificationAuthorization() async {
        let status = await notifications.requestAuthorizationIfNeeded()
        notificationAuthorization = status
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: status.isUsable
                ? .fact("уведомления \(status.description)")
                : .warning("уведомления \(status.description) — "
                    + "о переходах и ошибках сообщать будет нечем")))
    }

    /// Пока helper не отвечает, приложение переспрашивает его само: одобрение
    /// в Системных настройках и включение доступа CLI в Little Snitch иначе
    /// остались бы незамеченными до перезапуска или ручного «Обновить».
    /// Во время операции актор ждёт сам — вотчдог ему не мешает.
    private func startHelperWatchdog() {
        guard helperWatchdog == nil else { return }
        helperWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                if self.failsafeSyncPending { await self.syncFailsafe() }
                guard !self.helperState.isWorking else { continue }
                guard !self.diagnosis.isReady || self.groupsError != nil else { continue }
                await self.lifecycle.refresh()
                // Зеркало обновляется потоком чуть позже — решаем по актору.
                if await self.lifecycle.state.isResponsive {
                    await self.refreshRuleGroups()
                }
            }
        }
    }

    // MARK: - Действия поповера

    func probeNow() async {
        await coordinator.probeNowByUser()
    }

    func togglePause() async {
        if snapshot.state == .paused {
            await coordinator.resume()
        } else {
            await coordinator.pause()
        }
    }

    /// Завершение приложения (⌘Q, logout, выключение): координатор закрывает
    /// группы строгих детекторов перед смертью процесса.
    func prepareForTermination() async {
        await coordinator.prepareForTermination()
    }

    // MARK: - Настройки

    func update(_ transform: (inout AppSettings) -> Void) {
        let previous = settings
        var updated = settings
        transform(&updated)
        settings = DefaultsSettingsStore.sanitized(updated)
        settingsStore.save(settings)

        let monitoringToggled = previous.monitoringEnabled != settings.monitoringEnabled
        // Режим, группы и признак «включён» строгих детекторов, их добавление
        // и удаление, observeOnly — всё это сводится к failsafe-конфигу.
        let failsafeChanged = previous.failsafeConfig != settings.failsafeConfig
        let settings = settings
        Task {
            if failsafeChanged {
                // Страховка helper узнаёт о новом объединении до переходного
                // reconcile: иначе есть окно, где детектор уже строгий, а
                // dead-man's switch ещё не взведён.
                await syncFailsafe()
            }
            // Дифф детекторов делает координатор: переходные reconcile при
            // смене режима, выключении и удалении, перезапуск слоёв при смене
            // маяка, прокси или растяжки, старт включённых.
            await coordinator.settingsChanged()
            if monitoringToggled {
                // Выключенный мониторинг — та же остановка детекторов, что и
                // пауза: иначе поповер продолжал бы показывать «Защищено».
                if settings.monitoringEnabled {
                    await coordinator.resume()
                } else {
                    await coordinator.pause()
                }
            }
        }
        // Регистрация login item — системное изменение, поэтому только когда
        // пользователь переключил тумблер, а не при любой правке настроек.
        if previous.launchAtLogin != settings.launchAtLogin {
            loginItem.setEnabled(settings.launchAtLogin)
        }
    }

    // MARK: - Детекторы

    func updateDetector(_ id: DetectorID, _ transform: (inout DetectorConfig) -> Void) {
        update { settings in
            guard let index = settings.detectors.firstIndex(where: { $0.id == id }) else { return }
            transform(&settings.detectors[index])
        }
    }

    func toggleGroup(_ name: String, in id: DetectorID, isOn: Bool) {
        updateDetector(id) { detector in
            var groups = Set(detector.groups)
            if isOn { groups.insert(name) } else { groups.remove(name) }
            detector.groups = groups.sorted()
        }
    }

    /// «Добавить детектор…»: включённый детектор с дефолтами «Основного»,
    /// без групп. Возвращает идентификатор — экран сразу открывает детали.
    @discardableResult
    func addDetector() -> DetectorID {
        let id = DetectorID(UUID().uuidString)
        update { $0.detectors.append(.newDetector(id: id)) }
        return id
    }

    /// «Дублировать»: выключенная копия рядом с оригиналом.
    @discardableResult
    func duplicateDetector(_ id: DetectorID) -> DetectorID? {
        guard let original = settings.detector(id) else { return nil }
        let copyID = DetectorID(UUID().uuidString)
        update { settings in
            let index = settings.detectors.firstIndex { $0.id == id } ?? settings.detectors.count - 1
            settings.detectors.insert(original.duplicated(id: copyID), at: index + 1)
        }
        return copyID
    }

    /// Удаление после подтверждения: координатор открывает эксклюзивные
    /// группы детектора переходным reconcile (D9 design.md).
    func deleteDetector(_ id: DetectorID) {
        update { $0.detectors.removeAll { $0.id == id } }
    }

    // MARK: - Группы и helper

    /// Список групп запрашивается только у отвечающего демона: пока helper
    /// не установлен, ждёт одобрения или переустанавливается, вкладка
    /// показывает его состояние, а журнал не засоряется ошибками XPC.
    func refreshRuleGroups() async {
        guard !helperState.isWorking else { return }
        guard helperState.isResponsive else {
            groupsError = helperPresentation.statusText
            gatewayError = nil
            return
        }

        let outcome = await SyncRuleGroups(gateway: gateway,
                                           journal: journal,
                                           clock: SystemClock()).run()
        switch outcome {
        case .synced(let groups, _):
            ruleGroups = groups
            groupsError = nil
            gatewayError = nil
            groupsUpdatedAt = Date()
            // Дефолтная группа §13 подставляется в «Основной» один раз:
            // иначе она молча возвращалась бы каждый раз, когда пользователь
            // снял чекбокс.
            if !OnboardingState.isDefaultGroupApplied,
               settings.detector(.primary)?.groups.isEmpty == true,
               groups.contains(where: { $0.name == AppSettings.defaultLeakGroupName }) {
                OnboardingState.markDefaultGroupApplied()
                updateDetector(.primary) { $0.groups = [AppSettings.defaultLeakGroupName] }
            }
        case .failed(let error):
            groupsError = error.message
            gatewayError = error
        }
    }

    /// Переоценка состояния helper по фактам — при открытии окон.
    func refreshHelperState() async {
        await lifecycle.refresh()
    }

    func installHelper() async {
        await lifecycle.install()
    }

    /// Переустановка и удаление рвут XPC-соединения: presence снимаем
    /// заранее, чтобы dead-man's switch не принял разрыв за смерть
    /// приложения (D5). Обратно его включит syncFailsafe по «подключён».
    func reinstallHelper() async {
        await presence.setActive(false)
        await lifecycle.reinstall()
    }

    func removeHelper() async {
        await presence.setActive(false)
        await lifecycle.remove(strictModeActive: settings.strictActive)
    }

    /// Кнопка строки helper делает то, что велит представление; пока кнопка
    /// неактивна, действия нет.
    func performHelperAction() async {
        switch helperPresentation.action {
        case .install: await installHelper()
        case .reinstall: await reinstallHelper()
        case .remove: await removeHelper()
        case nil: break
        }
    }

    func openHelperApprovalSettings() async {
        await lifecycle.openApprovalSettings()
    }

    /// Единственный подписчик потока состояний актора: зеркалит состояние и
    /// по переходу в «отвечает» подтягивает группы и failsafe-конфиг.
    private func observeHelperState() {
        guard helperObserver == nil else { return }
        let lifecycle = self.lifecycle
        helperObserver = Task { [weak self] in
            for await state in await lifecycle.states() {
                guard let self else { return }
                await self.helperStateChanged(state)
            }
        }
    }

    private func helperStateChanged(_ state: HelperState) async {
        let wasResponsive = helperState.isResponsive
        helperState = state
        helperPresentation = HelperPresentation.make(state: state, now: await SystemClock().now())
        if state.isWorking {
            startHelperTicker()
        } else {
            helperTicker?.cancel()
            helperTicker = nil
        }
        if state.isResponsive {
            if !wasResponsive {
                await refreshRuleGroups()
                await syncFailsafe()
            }
        } else if !state.isWorking {
            groupsError = helperPresentation.statusText
            gatewayError = nil
        }
    }

    /// Счётчик «ждём launchd… N с» тикает раз в секунду: актор переиздаёт
    /// состояние только на тиках опроса (1, 2, 3, 5 с), и без своего таймера
    /// подпись выглядела застывшей (приёмка 2026-09-10).
    private func startHelperTicker() {
        guard helperTicker == nil else { return }
        helperTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.helperState.isWorking else { return }
                self.helperPresentation = HelperPresentation.make(
                    state: self.helperState, now: await SystemClock().now())
            }
        }
    }

    // MARK: - Журнал

    /// Полный текст журнала для экспорта — читается вместе с записями, чтобы
    /// выгрузка не зависела от экранного фильтра и лимита показа.
    private(set) var journalExportText = ""

    func refreshJournal() async {
        // Без отсечки: фильтр окна применяется по всей глубине хранения
        // (7 суток), лимит показа — забота отображения (JournalDisplay).
        journalEvents = await journal.recent(limit: .max)
        journalExportText = await journal.exportText()
    }

    func clearJournal() async {
        await journal.clear()
        journalEvents = []
    }

    func exportJournal() async -> String {
        await journal.exportText()
    }

    // MARK: - Онбординг

    func requestNotificationAuthorization() async -> Bool {
        let status = await notifications.requestAuthorizationIfNeeded()
        notificationAuthorization = status
        if status == .denied {
            // Повторно система не спросит — остаётся открыть настройки.
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications")!)
        }
        return status.isUsable
    }

    func openLittleSnitch() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Little Snitch.app"))
    }

    /// Приложение живёт в строке меню (`LSUIElement`), поэтому открытое окно
    /// само не выходит на передний план — его нужно активировать вручную,
    /// иначе кажется, что кнопка не сработала.
    func activateApp() {
        NSApplication.shared.activate()
    }

    /// Автозапуск включается именно здесь (§13: `launchAtLogin=true` после
    /// онбординга) — до этого регистрировать login item не за что.
    func finishOnboarding() {
        OnboardingState.markCompleted()
        isOnboardingPresented = false
        update { $0.launchAtLogin = true }
        loginItem.setEnabled(true)
    }
}

/// Отметка о пройденном онбординге живёт отдельно от настроек: это факт
/// установки, а не пользовательское предпочтение.
enum OnboardingState {
    private static let key = "onboardingCompleted"
    private static let defaultGroupKey = "defaultLeakGroupApplied"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Дефолтная группа §13 подставляется один раз за установку.
    static var isDefaultGroupApplied: Bool {
        UserDefaults.standard.bool(forKey: defaultGroupKey)
    }

    static func markDefaultGroupApplied() {
        UserDefaults.standard.set(true, forKey: defaultGroupKey)
    }
}
