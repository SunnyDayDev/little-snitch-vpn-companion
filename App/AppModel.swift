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
    private(set) var helperStatus: HelperInstaller.Status
    private(set) var helperVersion: String?
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

    /// Единый диагноз для поповера и настроек: раньше они показывали разное
    /// («подключён · root» и «недоступен» одновременно), потому что смотрели
    /// в разные источники.
    enum Diagnosis: Hashable {
        case ready
        case helperNotInstalled(HelperInstaller.Status)
        case littleSnitchNotAuthorized
        case failing(String)

        var title: String {
            switch self {
            case .ready: "подключён · root"
            case .helperNotInstalled(let status): status.description
            case .littleSnitchNotAuthorized: "Little Snitch не пускает CLI"
            case .failing(let text): text
            }
        }

        var isReady: Bool { self == .ready }
    }

    var diagnosis: Diagnosis {
        if let gatewayError {
            return gatewayError.isLittleSnitchAuthorization
                ? .littleSnitchNotAuthorized
                : (helperStatus.isReady ? .failing(gatewayError.message)
                                        : .helperNotInstalled(helperStatus))
        }
        guard helperStatus.isReady else { return .helperNotInstalled(helperStatus) }
        return .ready
    }

    private let coordinator: MonitoringCoordinator
    private let settingsStore: any SettingsStore
    private let journal: FileJournalStore
    private let gateway: HelperRuleGroupGateway
    private let installer = HelperInstaller()
    private let notifications: UserNotificationsPresenter
    private let loginItem = LoginItemController()
    /// Presence-соединение строгого режима (D5): его пропажу helper считает
    /// сигналом dead-man's switch.
    private let presence = HelperPresenceConnection()
    private var observerID: Int?
    private var didReinstallStaleHelper = false
    private var didRecoverSilentHelper = false
    private var didRestoreHelper = false
    private var helperWatchdog: Task<Void, Never>?
    private var didJournalHelperStatus = false
    private var didPromptForApproval = false
    /// Последний syncFailsafe не дошёл до helper — вотчдог обязан повторить,
    /// иначе устаревший конфиг на диске сработает после выхода приложения.
    private var failsafeSyncPending = false

    init(coordinator: MonitoringCoordinator,
         settingsStore: any SettingsStore,
         journal: FileJournalStore,
         gateway: HelperRuleGroupGateway,
         notifications: UserNotificationsPresenter,
         settings: AppSettings) {
        self.coordinator = coordinator
        self.settingsStore = settingsStore
        self.journal = journal
        self.gateway = gateway
        self.notifications = notifications
        self.settings = settings
        helperStatus = installer.status
        isOnboardingPresented = !OnboardingState.isCompleted
    }

    // MARK: - Жизненный цикл

    func start() async {
        observerID = await coordinator.observe { [weak self] snapshot in
            Task { @MainActor in self?.snapshot = snapshot }
        }
        if settings.monitoringEnabled {
            await coordinator.start()
        }
        await refreshHelperState()
        await refreshRuleGroups()
        // После проверки версии helper: устаревшему демону без setFailsafe
        // конфиг слать бессмысленно, а к этому моменту он уже переустановлен.
        await syncFailsafe()
        await ensureNotificationAuthorization()
        await restoreLoginItemIfLost()
        startHelperWatchdog()
    }

    /// Синхронизация failsafe-страховки helper (D5): активна только когда
    /// строгий режим включён и не перекрыт observeOnly. Presence-соединение
    /// держится ровно при активной страховке. Ошибка не фатальна — первый
    /// эшелон (закрытие при выходе) работает и без helper, — но обязана
    /// ретраиться вотчдогом: устаревший strict-конфиг на диске helper иначе
    /// запер бы реактивного пользователя после выхода из приложения.
    private func syncFailsafe() async {
        let strictActive = settings.protectionMode == .strict && !settings.observeOnly
        await presence.setActive(strictActive)
        do {
            try await gateway.syncFailsafe(FailsafeConfig(
                strictActive: strictActive,
                groups: settings.leakGroups))
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
    private func startHelperWatchdog() {
        guard helperWatchdog == nil else { return }
        helperWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled else { return }
                if self.failsafeSyncPending { await self.syncFailsafe() }
                guard !self.diagnosis.isReady || self.groupsError != nil else { continue }
                await self.refreshHelperState()
                await self.refreshRuleGroups()
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

    /// Завершение приложения (⌘Q, logout, выключение): в строгом режиме
    /// координатор закрывает группы перед смертью процесса.
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
        let mappingChanged = previous.leakGroups != settings.leakGroups
        let modeChanged = previous.protectionMode != settings.protectionMode
        let observeToggled = previous.observeOnly != settings.observeOnly
        let failsafeChanged = modeChanged || mappingChanged || observeToggled
        Task {
            await coordinator.settingsChanged()
            if failsafeChanged {
                // Страховка helper узнаёт о новом режиме до переходного
                // reconcile: иначе есть окно, где режим уже строгий, а
                // dead-man's switch ещё не взведён.
                await syncFailsafe()
            }
            if modeChanged {
                // Переходный reconcile выполняет координатор: строгий закрывает
                // всё, кроме Protected, реактивный открывает всё, кроме Leak.
                await coordinator.protectionModeChanged()
            }
            if monitoringToggled {
                // Выключенный мониторинг — та же остановка детектора, что и
                // пауза: иначе поповер продолжал бы показывать «Защищено».
                if settings.monitoringEnabled {
                    await coordinator.resume()
                } else {
                    await coordinator.pause()
                }
            } else if mappingChanged || observeToggled, !modeChanged {
                // Снятие observeOnly при строгом режиме обязано закрыть
                // немедленно, а не ближайшей плановой пробой через минуту.
                await coordinator.reconcileNow()
            }
        }
        // Регистрация login item — системное изменение, поэтому только когда
        // пользователь переключил тумблер, а не при любой правке настроек.
        if previous.launchAtLogin != settings.launchAtLogin {
            loginItem.setEnabled(settings.launchAtLogin)
        }
    }

    func toggleLeakGroup(_ name: String, isOn: Bool) {
        update { settings in
            var groups = Set(settings.leakGroups)
            if isOn { groups.insert(name) } else { groups.remove(name) }
            settings.leakGroups = groups.sorted()
        }
    }

    // MARK: - Группы и helper

    func refreshRuleGroups() async {
        // Версию спрашиваем отдельно от списка групп: список может не
        // разобраться, а устаревший демон надо переустановить именно тогда.
        await checkHelperVersion()

        let outcome = await SyncRuleGroups(gateway: gateway,
                                           journal: journal,
                                           clock: SystemClock()).run()
        switch outcome {
        case .synced(let groups, let version):
            ruleGroups = groups
            helperVersion = version ?? helperVersion
            groupsError = nil
            gatewayError = nil
            groupsUpdatedAt = Date()
            // Дефолтная группа §13 подставляется один раз: иначе она молча
            // возвращалась бы каждый раз, когда пользователь снял чекбокс.
            if !OnboardingState.isDefaultGroupApplied,
               settings.leakGroups.isEmpty,
               groups.contains(where: { $0.name == AppSettings.defaultLeakGroupName }) {
                OnboardingState.markDefaultGroupApplied()
                update { $0.leakGroups = [AppSettings.defaultLeakGroupName] }
            }
        case .failed(let error):
            groupsError = error.message
            gatewayError = error
        }
        await refreshHelperState()
    }

    func refreshHelperState() async {
        let previous = helperStatus
        helperStatus = installer.status
        if previous != helperStatus || !didJournalHelperStatus {
            didJournalHelperStatus = true
            await journal.append(JournalEvent(
                time: await SystemClock().now(),
                kind: .fact("статус helper: \(helperStatus)")))
        }
        await restoreHelperIfLost()
        await promptForApprovalIfNeeded()
    }

    /// Пока macOS ждёт одобрения объекта входа, демон не запускается вовсе.
    /// Сам пользователь про это не догадается, поэтому один раз за запуск
    /// открываем нужный раздел настроек.
    private func promptForApprovalIfNeeded() async {
        guard helperStatus == .requiresApproval, !didPromptForApproval else { return }
        didPromptForApproval = true
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: .warning("helper ждёт одобрения: Системные настройки → Основные "
                + "→ Объекты входа → включить Little Snitch VPN Companion")))
        installer.openApprovalSettings()
    }

    /// Онбординг пройден, а демона в системе нет — значит регистрация слетела
    /// (например при обновлении приложения). Восстанавливаем её сами: согласие
    /// пользователь уже давал, а без helper приложение бесполезно.
    private func restoreHelperIfLost() async {
        guard OnboardingState.isCompleted,
              helperStatus == .notRegistered,
              !didRestoreHelper else { return }
        didRestoreHelper = true
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: .warning("регистрация helper потеряна — восстанавливаем")))
        do {
            try installer.register()
        } catch {
            groupsError = "не удалось восстановить helper: \(error.localizedDescription)"
        }
        helperStatus = installer.status
    }

    /// launchd держит демон в памяти, поэтому после обновления приложения в
    /// системе может работать устаревший helper — с прежним кодом и прежними
    /// ошибками. Замечаем расхождение версий и переустанавливаем демон один
    /// раз за запуск.
    private func checkHelperVersion() async {
        guard helperStatus.isReady else { return }
        guard let runningVersion = try? await gateway.helperVersion() else {
            // Демон зарегистрирован, но не отвечает. Типичная причина —
            // приложение пересобрано: launchd отказывается запускать бинарь,
            // не совпадающий с подписью на момент регистрации (EX_CONFIG).
            guard !didReinstallStaleHelper else { return }
            await journal.append(JournalEvent(
                time: await SystemClock().now(),
                kind: .warning("helper не отвечает — обновляем регистрацию")))
            await updateHelperRegistration()
            return
        }
        helperVersion = runningVersion
        guard !didReinstallStaleHelper,
              runningVersion != installer.bundledHelperVersion else { return }
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: .warning("helper устарел (\(runningVersion) вместо "
                + "\(installer.bundledHelperVersion)) — обновляем регистрацию")))
        await updateHelperRegistration()
    }

    func installHelper() async {
        do {
            try installer.register()
        } catch {
            groupsError = "не удалось зарегистрировать helper: \(error.localizedDescription)"
        }
        await refreshHelperState()
        if helperStatus == .requiresApproval {
            installer.openApprovalSettings()
        }
    }

    func reinstallHelper() async {
        // Переустановка рвёт XPC-соединения: снимаем супервизию заранее, чтобы
        // dead-man's switch не принял её за смерть приложения (D5).
        try? await gateway.syncFailsafe(FailsafeConfig(strictActive: false, groups: []))
        await gateway.invalidate()
        do {
            // Явное действие пользователя — сразу полный цикл: мягкая
            // перерегистрация не лечит выгруженный вручную job.
            try await installer.reinstall(forceFullCycle: true)
        } catch {
            groupsError = "не удалось переустановить helper: \(error.localizedDescription)"
        }
        await refreshHelperState()
        // launchd поднимает демон по требованию, и первый вызов сразу после
        // регистрации обычно не успевает: ждём, пока helper реально ответит,
        // вместо того чтобы показывать ошибку и просить нажать ещё раз.
        if await !waitForHelperToAnswer() {
            await recoverSilentHelperIfNeeded()
        }
        await refreshRuleGroups()
        await syncFailsafe()
    }

    /// Перерегистрация демона — единственный способ подсунуть launchd новый
    /// бинарь helper. Делается один раз за запуск: macOS может попросить
    /// одобрить объект входа заново, и дёргать пользователя чаще нельзя.
    private func updateHelperRegistration() async {
        // Check-and-set до первого await: конкурентные вызовы (start и
        // вотчдог) иначе оба проходят внешние guard'ы и чинят регистрацию
        // дважды, сбрасывая одобрение, которое пользователь только что дал.
        guard !didReinstallStaleHelper else { return }
        didReinstallStaleHelper = true
        // См. reinstallHelper(): супервизию снимаем до разрыва соединений.
        try? await gateway.syncFailsafe(FailsafeConfig(strictActive: false, groups: []))
        await gateway.invalidate()
        do {
            try await installer.reinstall()
        } catch {
            groupsError = "не удалось обновить helper: \(error.localizedDescription)"
        }
        await refreshHelperState()
        if await !waitForHelperToAnswer() {
            await recoverSilentHelperIfNeeded()
        }
        helperVersion = try? await gateway.helperVersion()
        await syncFailsafe()

        // Если macOS ждёт одобрения — открываем нужный раздел настроек сразу:
        // сам пользователь про этот шаг не догадается.
        if helperStatus == .requiresApproval {
            await journal.append(JournalEvent(
                time: await SystemClock().now(),
                kind: .warning("helper ждёт одобрения в Системных настройках "
                    + "→ Основные → Объекты входа")))
            installer.openApprovalSettings()
        }
    }

    /// Опрашивает helper, пока он не ответит (или не кончится терпение).
    /// Нужен и после переустановки, и после одобрения в Системных настройках:
    /// одобрение приложение никак иначе не заметит.
    @discardableResult
    private func waitForHelperToAnswer(attempts: Int = 5) async -> Bool {
        for attempt in 1...attempts {
            if (try? await gateway.helperVersion()) != nil {
                gatewayError = nil
                groupsError = nil
                return true
            }
            guard attempt < attempts else { return false }
            try? await Task.sleep(for: .seconds(2))
            await gateway.invalidate()
        }
        return false
    }

    /// Мягкая перерегистрация может «пройти» вхолостую: если job выгружали
    /// вручную (launchctl bootout), база SMAppService всё ещё считает демон
    /// зарегистрированным, `register()` возвращает успех, а слушателя в launchd
    /// нет. Замечаем это по молчанию демона и делаем полный цикл
    /// unregister → register.
    private func recoverSilentHelperIfNeeded() async {
        // Один раз за запуск и только когда демон числится включённым:
        // повторные полные циклы сбрасывали бы одобрение быстрее, чем
        // пользователь успевает его дать («ждёт одобрения» → тумблер →
        // снова «ждёт одобрения»).
        guard helperStatus.isReady, !didRecoverSilentHelper else { return }
        didRecoverSilentHelper = true
        await journal.append(JournalEvent(
            time: await SystemClock().now(),
            kind: .warning("helper зарегистрирован, но не отвечает — полная переустановка")))
        do {
            try await installer.reinstall(forceFullCycle: true)
        } catch {
            groupsError = "не удалось переустановить helper: \(error.localizedDescription)"
            return
        }
        await refreshHelperState()
        await waitForHelperToAnswer()
    }

    // MARK: - Журнал

    /// Полный текст журнала для экспорта — читается вместе с записями, чтобы
    /// выгрузка не зависела от экранного фильтра и лимита показа.
    private(set) var journalExportText = ""

    func refreshJournal() async {
        journalEvents = await journal.recent(limit: 500)
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
