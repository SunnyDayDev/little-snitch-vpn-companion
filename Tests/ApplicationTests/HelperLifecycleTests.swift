import Foundation
import Testing

/// Жизненный цикл helper на фейках: ни SMAppService, ни XPC, ни реальных
/// таймеров. Время двигает `ManualClock`: каждый шаг — до ближайшего
/// дедлайна сна актора, поэтому тесты не знают интервалы наизусть.
@Suite("HelperLifecycle")
struct HelperLifecycleTests {
    private struct Harness {
        let lifecycle: HelperLifecycle
        let registrar: FakeHelperRegistrar
        let gateway: FakeRuleGroupGateway
        let failsafe: FakeFailsafeSync
        let facts: FakeHelperInstallFacts
        let journal: FakeJournal
        let clock: ManualClock
    }

    /// Короткий бюджет: 10 с и интервалы 1, 2, 3 — один бюджет исчерпывается
    /// за пять снов (1, 3, 6, 9, 12 с).
    /// Пауза после выгрузки job — ноль: иначе каждый полный цикл добавлял бы
    /// сон, который тесты должны были бы знать наизусть. Сама пауза проверяется
    /// отдельным тестом с собственной политикой.
    private static let policy = HelperWaitPolicy(
        budgetSeconds: 10, intervals: [1, 2, 3],
        unregistrationBudgetSeconds: 3, unregistrationStepSeconds: 0.1,
        removalBudgetSeconds: 2, removalStepSeconds: 0.5,
        jobUnloadBudgetSeconds: 3, jobUnloadStepSeconds: 0.5, jobUnloadGraceSeconds: 0,
        registerRetryIntervals: [0.5, 1])
    private static let sleepsPerBudget = 5

    private func makeHarness(status: HelperRegistrationStatus,
                             bundled: String = "1.0",
                             removedByUser: Bool = false,
                             onboardingCompleted: Bool = true,
                             policy: HelperWaitPolicy = HelperLifecycleTests.policy) -> Harness {
        let registrar = FakeHelperRegistrar(status: status, bundledVersion: bundled)
        let gateway = FakeRuleGroupGateway()
        let failsafe = FakeFailsafeSync()
        let facts = FakeHelperInstallFacts(removedByUser: removedByUser)
        let journal = FakeJournal()
        let clock = ManualClock()
        let lifecycle = HelperLifecycle(
            registrar: registrar, gateway: gateway, failsafe: failsafe, facts: facts,
            journal: journal, clock: clock, policy: policy,
            onboardingCompleted: { onboardingCompleted })
        return Harness(lifecycle: lifecycle, registrar: registrar, gateway: gateway,
                       failsafe: failsafe, facts: facts, journal: journal, clock: clock)
    }

    /// Ждёт, пока актор уснёт, со сторожем по реальному времени: ошибка в
    /// числе шагов валит тест, а не вешает прогон.
    private func sleeperAppears(_ clock: ManualClock, timeoutSeconds: Double = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await clock.waitForSleepers(1); return true }
            group.addTask { try? await Task.sleep(for: .seconds(timeoutSeconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// `times` снов актора: дождаться каждого и шагнуть к его дедлайну.
    private func step(_ h: Harness, times: Int) async {
        for _ in 0..<times {
            #expect(await sleeperAppears(h.clock), "актор не уснул — шагов больше, чем снов")
            await h.clock.advanceToNextDeadline()
        }
    }

    private func errors(_ journal: FakeJournal) async -> [String] {
        await journal.events.compactMap {
            if case .error(let text) = $0.kind { return text }
            return nil
        }
    }

    private func warnings(_ journal: FakeJournal) async -> [String] {
        await journal.events.compactMap {
            if case .warning(let text) = $0.kind { return text }
            return nil
        }
    }

    private func facts(_ journal: FakeJournal) async -> [String] {
        await journal.events.compactMap {
            if case .fact(let text) = $0.kind { return text }
            return nil
        }
    }

    // MARK: - Состояние по фактам

    @Test("Подключён: зарегистрирован, отвечает, версия совпадает")
    func readyWhenVersionMatches() async {
        let h = makeHarness(status: .enabled)
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 0)
        #expect(await facts(h.journal).contains { $0.contains("подключён") })
    }

    @Test("Не найден в бандле и не установлен без онбординга")
    func notFoundAndNotInstalled() async {
        let broken = makeHarness(status: .notFound)
        await broken.lifecycle.start()
        #expect(await broken.lifecycle.state == .notFound)

        let fresh = makeHarness(status: .notRegistered, onboardingCompleted: false)
        await fresh.lifecycle.start()
        #expect(await fresh.lifecycle.state == .notInstalled)
        #expect(fresh.registrar.registerCount == 0)
    }

    @Test("Ждёт одобрения: настройки открываются один раз за запуск")
    func awaitingApprovalPromptsOnce() async {
        let h = makeHarness(status: .requiresApproval)
        await h.lifecycle.start()
        await h.lifecycle.refresh()
        #expect(await h.lifecycle.state == .awaitingApproval)
        #expect(h.registrar.approvalPromptCount == 1)
        #expect(await warnings(h.journal).filter { $0.contains("ждёт одобрения") }.count == 1)
    }

    // MARK: - Ожидание после регистрации

    @Test("Демон ответил внутри бюджета: без полного цикла и без ошибок")
    func answersWithinBudget() async {
        let h = makeHarness(status: .notRegistered)
        await h.gateway.answerVersion(fromCall: 4)
        let op = Task { await h.lifecycle.install() }
        await step(h, times: 3)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 1)
        #expect(h.registrar.unregisterCount == 0)
        #expect(await errors(h.journal).isEmpty)
        #expect(await h.gateway.resetConnectionCount >= 3)
        let facts = await facts(h.journal)
        #expect(facts.contains("устанавливаем helper"))
        #expect(facts.contains { $0.contains("подключён") })
    }

    @Test("Счётчик ожидания переиздаётся с тем же началом")
    func workingStateIsReemitted() async {
        let h = makeHarness(status: .notRegistered)
        await h.gateway.answerVersion(fromCall: 3)
        let stream = await h.lifecycle.states()
        let collected = Task { () -> [HelperState] in
            var seen: [HelperState] = []
            for await state in stream {
                seen.append(state)
                if case .ready = state { break }
            }
            return seen
        }
        let op = Task { await h.lifecycle.install() }
        await step(h, times: 2)
        await op.value
        let states = await collected.value
        let working = states.filter(\.isWorking)
        #expect(working.count == 3)
        #expect(Set(working).count == 1, "startedAt не меняется между тиками")
    }

    @Test("Бюджет исчерпан: один полный цикл, потом ответ")
    func fullCycleAfterBudget() async {
        let h = makeHarness(status: .notRegistered)
        let registrar = h.registrar
        await h.gateway.answerVersion(when: { registrar.unregisterCount > 0 })
        let op = Task { await h.lifecycle.install() }
        await step(h, times: Self.sleepsPerBudget)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.unregisterCount == 1)
        #expect(h.registrar.registerCount == 2)
        #expect(await errors(h.journal).isEmpty)
    }

    @Test("Молчит после полного цикла: одна ошибка, одно предупреждение")
    func silentAfterFullCycle() async {
        let h = makeHarness(status: .notRegistered)
        await h.gateway.silenceVersion()
        let op = Task { await h.lifecycle.install() }
        await step(h, times: Self.sleepsPerBudget * 2)
        await op.value

        guard case .silent(let lastError) = await h.lifecycle.state else {
            Issue.record("ожидалось «молчит», получено \(await h.lifecycle.state)")
            return
        }
        #expect(lastError.contains("No such process"))
        #expect(h.registrar.unregisterCount == 1)
        #expect(h.registrar.registerCount == 2)
        let errors = await errors(h.journal)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("No such process") == true)
        #expect(await warnings(h.journal).filter { $0.contains("не отвечает") }.count == 1)

        // Вотчдог продолжает: первый ответ переводит в «подключён».
        await h.gateway.answerVersion(fromCall: 0)
        await h.lifecycle.refresh()
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 2, "повторного цикла нет")
    }

    @Test("Одобрение требуется во время ожидания: цикла нет, настройки открыты один раз")
    func approvalInterruptsWaiting() async {
        let h = makeHarness(status: .notRegistered)
        h.registrar.setStatusAfterRegister(.requiresApproval)
        await h.gateway.silenceVersion()
        await h.lifecycle.install()

        #expect(await h.lifecycle.state == .awaitingApproval)
        #expect(h.registrar.registerCount == 1)
        #expect(h.registrar.unregisterCount == 0)
        #expect(h.registrar.approvalPromptCount == 1)
        #expect(await errors(h.journal).isEmpty)
    }

    @Test("Одобрение получено: ожидание без новой регистрации")
    func approvalGrantedWaitsWithoutRegister() async {
        let h = makeHarness(status: .notRegistered)
        h.registrar.setStatusAfterRegister(.requiresApproval)
        await h.gateway.silenceVersion()
        await h.lifecycle.install()
        #expect(await h.lifecycle.state == .awaitingApproval)

        // Пользователь включил объект входа; демон поднимается не сразу.
        h.registrar.setStatus(.enabled)
        await h.gateway.answerVersion(fromCall: 4)
        let op = Task { await h.lifecycle.refresh() }
        await step(h, times: 2)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 1, "регистрация не повторялась")
    }

    // MARK: - Одна операция за раз

    @Test("Повторная переустановка присоединяется к текущей")
    func concurrentReinstallsCoalesce() async {
        let h = makeHarness(status: .enabled)
        async let first: Void = h.lifecycle.reinstall()
        async let second: Void = h.lifecycle.reinstall()
        _ = await (first, second)

        #expect(h.registrar.unregisterCount == 1)
        #expect(h.registrar.registerCount == 1)
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
    }

    @Test("Вотчдог во время операции ничего не начинает")
    func refreshDuringOperationIsNoop() async {
        let h = makeHarness(status: .notRegistered)
        await h.gateway.answerVersion(fromCall: 3)
        let op = Task { await h.lifecycle.install() }
        await step(h, times: 1)
        await h.lifecycle.refresh()
        #expect(await h.lifecycle.state.isWorking)
        #expect(h.registrar.registerCount == 1)
        await step(h, times: 1)
        await op.value
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
    }

    // MARK: - Авто-восстановление

    @Test("Бандл заменён: регистрация восстанавливается с ожиданием")
    func restoresLostRegistration() async {
        let h = makeHarness(status: .notRegistered)
        await h.gateway.answerVersion(fromCall: 2)
        let op = Task { await h.lifecycle.start() }
        await step(h, times: 1)
        await op.value

        #expect(h.registrar.registerCount == 1)
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(await warnings(h.journal).contains { $0.contains("восстанавливаем") })
        #expect(await errors(h.journal).isEmpty)
    }

    @Test("Удалённый пользователем helper не возвращается")
    func removedHelperIsNotRestored() async {
        let h = makeHarness(status: .notRegistered, removedByUser: true)
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .notInstalled)
        #expect(h.registrar.registerCount == 0)
        #expect(await warnings(h.journal).isEmpty)
    }

    @Test("Установка после удаления снимает флаг")
    func installClearsRemovalFlag() async {
        let h = makeHarness(status: .notRegistered, removedByUser: true)
        await h.lifecycle.install()
        #expect(!h.facts.removedByUser)
        #expect(h.registrar.registerCount == 1)
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
    }

    // MARK: - Проверка версии

    @Test("Устаревший демон обновляется один раз за запуск")
    func staleDaemonIsUpdatedOnce() async {
        let h = makeHarness(status: .enabled, bundled: "1.0 (build 2)")
        let registrar = h.registrar
        await h.gateway.setVersionProvider {
            registrar.registerCount > 0 ? "1.0 (build 2)" : "1.0 (build 1)"
        }
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .ready(version: "1.0 (build 2)"))
        #expect(h.registrar.registerCount == 1)
        #expect(h.registrar.unregisterCount == 0)
        #expect(await warnings(h.journal).contains { $0.contains("устарел") })
    }

    @Test("Старый демон в памяти после регистрации поверх — перезапуск полным циклом")
    func staleDaemonIsRestartedByFullCycle() async {
        let h = makeHarness(status: .enabled, bundled: "1.0 (build 2)")
        let registrar = h.registrar
        await h.gateway.setVersionProvider {
            registrar.unregisterCount > 0 ? "1.0 (build 2)" : "1.0 (build 1)"
        }
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .ready(version: "1.0 (build 2)"))
        #expect(h.registrar.registerCount == 2)
        #expect(h.registrar.unregisterCount == 1)
        #expect(await warnings(h.journal).contains { $0.contains("остался в памяти") })
    }

    @Test("Версия не совпала и после полного цикла: «устарел», повтора нет")
    func staysStaleAfterOneUpdate() async {
        let h = makeHarness(status: .enabled, bundled: "1.0 (build 2)")
        await h.gateway.setVersion("1.0 (build 1)")
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .stale(running: "1.0 (build 1)", bundled: "1.0 (build 2)"))
        #expect(h.registrar.registerCount == 2)
        #expect(h.registrar.unregisterCount == 1)

        await h.lifecycle.refresh()
        #expect(h.registrar.registerCount == 2, "второго автоматического обновления нет")
        #expect(await h.lifecycle.state == .stale(running: "1.0 (build 1)", bundled: "1.0 (build 2)"))
    }

    @Test("Зарегистрирован, но молчит при старте: регистрация обновляется")
    func silentAtStartIsUpdated() async {
        let h = makeHarness(status: .enabled)
        let registrar = h.registrar
        await h.gateway.answerVersion(when: { registrar.registerCount > 0 })
        await h.lifecycle.start()
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 1)
    }

    // MARK: - Полный цикл: снятие, выгрузка job, регистрация

    @Test("register повторяется при временной ошибке сразу после снятия")
    func registerRetriesTransientError() async {
        let h = makeHarness(status: .notRegistered)
        h.registrar.failRegister(times: 2)
        let op = Task { await h.lifecycle.install() }
        await step(h, times: 2)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 1)
        #expect(await warnings(h.journal).filter { $0.contains("повтор через") }.count == 2)
        #expect(await errors(h.journal).isEmpty)
    }

    @Test("register не прошёл и после повторов: одна ошибка, состояние по фактам")
    func registerGivesUpAfterRetries() async {
        let h = makeHarness(status: .notRegistered)
        h.registrar.failRegister(times: 10)
        let op = Task { await h.lifecycle.install() }
        await step(h, times: 2)
        await op.value

        #expect(await h.lifecycle.state == .notInstalled)
        #expect(h.registrar.registerCount == 0)
        #expect(await errors(h.journal).count == 1)
    }

    @Test("После снятия регистрация ждёт выгрузки job из launchd и паузы")
    func fullCycleWaitsForJobUnload() async {
        var policy = Self.policy
        policy.jobUnloadGraceSeconds = 2
        let h = makeHarness(status: .enabled, policy: policy)
        h.registrar.setJobLoaded(true)
        let op = Task { await h.lifecycle.reinstall() }
        // Два опроса job, оба «ещё загружен»; затем job исчезает.
        await step(h, times: 2)
        h.registrar.clearJobLoadedOverride()
        // Опрос «выгружен» → пауза 2 с → регистрация.
        await step(h, times: 1)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.unregisterCount == 1)
        #expect(h.registrar.registerCount == 1)
        #expect(h.registrar.jobProbeCount >= 3)
        #expect(await warnings(h.journal).isEmpty)
    }

    @Test("Job не выгрузился за бюджет: регистрируем поверх с предупреждением")
    func fullCycleGivesUpWaitingForJobUnload() async {
        let h = makeHarness(status: .enabled)
        h.registrar.setJobLoaded(true)
        let op = Task { await h.lifecycle.reinstall() }
        // Бюджет 3 с шагом 0.5: шесть снов.
        await step(h, times: 6)
        await op.value

        #expect(await h.lifecycle.state == .ready(version: "1.0"))
        #expect(h.registrar.registerCount == 1)
        #expect(await warnings(h.journal).contains { $0.contains("не выгрузился") })
    }

    // MARK: - Удаление

    @Test("Удаление в строгом режиме: failsafe снят до снятия регистрации")
    func removeInStrictMode() async {
        let h = makeHarness(status: .enabled)
        await h.lifecycle.start()
        await h.lifecycle.remove(strictModeActive: true)

        #expect(await h.failsafe.configs == [.inactive])
        #expect(h.registrar.unregisterCount == 1)
        #expect(h.facts.removedByUser)
        #expect(await h.lifecycle.state == .notInstalled)
        #expect(await warnings(h.journal).contains { $0.contains("строгий режим") })
        #expect(await h.gateway.operations.isEmpty, "группы не трогаются")
    }

    @Test("Снятие регистрации не завершилось: одна ошибка, кнопка снова активна")
    func removalThatDoesNotComplete() async {
        let h = makeHarness(status: .enabled)
        h.registrar.setStatusAfterUnregister(.enabled)
        let op = Task { await h.lifecycle.remove(strictModeActive: false) }
        await step(h, times: 4)
        await op.value

        #expect(await errors(h.journal).count == 1)
        #expect(!h.facts.removedByUser)
        #expect(await h.lifecycle.state == .ready(version: "1.0"))
    }

    // MARK: - Журнал

    @Test("Переход в «подключён» пишется один раз")
    func readyIsJournaledOnce() async {
        let h = makeHarness(status: .enabled)
        await h.lifecycle.start()
        await h.lifecycle.refresh()
        await h.lifecycle.refresh()
        #expect(await facts(h.journal).filter { $0.contains("подключён") }.count == 1)
    }
}

@Suite("HelperPresentation")
struct HelperPresentationTests {
    private let now = Instant(secondsSinceEpoch: 1_000)

    private func make(_ state: HelperState) -> HelperPresentation {
        HelperPresentation.make(state: state, now: now)
    }

    @Test("Не установлен: «Установить…» активна")
    func notInstalled() {
        let p = make(.notInstalled)
        #expect(p.buttonTitle == "Установить…")
        #expect(p.isButtonEnabled && p.action == .install)
        #expect(p.statusText == "не установлен" && p.tone == .normal)
        #expect(!p.showsApprovalLink)
    }

    @Test("Не найден в бандле: кнопка неактивна, тон ошибки")
    func notFound() {
        let p = make(.notFound)
        #expect(p.buttonTitle == "Установить…")
        #expect(!p.isButtonEnabled && p.action == nil)
        #expect(p.tone == .danger)
    }

    @Test("Ждёт одобрения: ссылка в статусе, кнопка «Удалить…»")
    func awaitingApproval() {
        let p = make(.awaitingApproval)
        #expect(p.buttonTitle == "Удалить…" && p.action == .remove)
        #expect(p.showsApprovalLink && p.tone == .warning)
        #expect(p.statusText == "ждёт одобрения в Системных настройках")
    }

    @Test("В работе: кнопка называет операцию, счётчик растёт")
    func working() {
        let started = now.adding(seconds: -12)
        let install = make(.working(.install, startedAt: started))
        #expect(install.buttonTitle == "Устанавливаем…" && !install.isButtonEnabled)
        #expect(install.statusText == "устанавливаем: ждём launchd… 12 с")

        let reinstall = make(.working(.reinstall, startedAt: started))
        #expect(reinstall.buttonTitle == "Переустанавливаем…")
        #expect(reinstall.statusText == "переустанавливаем: ждём launchd… 12 с")

        let remove = make(.working(.remove, startedAt: started))
        #expect(remove.buttonTitle == "Удаляем…")
        #expect(remove.statusText == "снимаем регистрацию…")

        let future = make(.working(.install, startedAt: now.adding(seconds: 5)))
        #expect(future.statusText.hasSuffix("0 с"), "часы назад — счётчик не отрицательный")
    }

    @Test("Подключён: «Удалить…» и версия")
    func ready() {
        let p = make(.ready(version: "1.0 (build 7)"))
        #expect(p.buttonTitle == "Удалить…" && p.action == .remove)
        #expect(p.statusText == "v1.0 (build 7) · подключён · root" && p.tone == .normal)
    }

    @Test("Устарел и молчит: «Переустановить…» с предупреждением")
    func staleAndSilent() {
        let stale = make(.stale(running: "1.0 (build 1)", bundled: "1.0 (build 2)"))
        #expect(stale.buttonTitle == "Переустановить…" && stale.action == .reinstall)
        #expect(stale.statusText == "v1.0 (build 1) · устарел, в бандле новее" && stale.tone == .warning)

        let silent = make(.silent(lastError: "No such process"))
        #expect(silent.buttonTitle == "Переустановить…" && silent.action == .reinstall)
        #expect(silent.statusText == "зарегистрирован, но не отвечает" && silent.tone == .warning)
    }
}
