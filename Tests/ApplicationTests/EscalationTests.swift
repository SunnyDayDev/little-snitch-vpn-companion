import Testing

@Suite("HandleHelperFailure — эскалация")
struct EscalationTests {
    private func makeUseCase(_ wifi: FakeWifi,
                             journal: FakeJournal = FakeJournal(),
                             notifications: FakeNotifications = FakeNotifications())
        -> HandleHelperFailure {
        HandleHelperFailure(wifi: wifi, journal: journal,
                            notifications: notifications, clock: ImmediateClock())
    }

    @Test("Leak + helper недоступен → Wi-Fi выключен, уведомление отправлено")
    func escalatesOnLeak() async {
        let wifi = FakeWifi()
        let notifications = FakeNotifications()
        let outcome = await makeUseCase(wifi, notifications: notifications)
            .run(state: .leak, settings: TestData.settings())

        #expect(outcome == .escalated)
        #expect(await wifi.turnedOffCount == 1)
        #expect(await notifications.presented.count == 1)
        #expect(await notifications.presented.first?.category == .error)
    }

    @Test("Вне Leak эскалации нет")
    func doesNotEscalateOutsideLeak() async {
        let wifi = FakeWifi()
        let useCase = makeUseCase(wifi)
        #expect(await useCase.run(state: .protected, settings: TestData.settings()) == .skippedNotLeaking)
        #expect(await useCase.run(state: .offline, settings: TestData.settings()) == .skippedNotLeaking)
        #expect(await wifi.turnedOffCount == 0)
    }

    @Test("Эскалация отключена настройкой → Wi-Fi не трогаем")
    func respectsDisabledSetting() async {
        let wifi = FakeWifi()
        var settings = TestData.settings()
        settings.escalationEnabled = false
        let outcome = await makeUseCase(wifi).run(state: .leak, settings: settings)
        #expect(outcome == .skippedDisabled)
        #expect(await wifi.turnedOffCount == 0)
    }

    @Test("Режим наблюдения → Wi-Fi не трогаем")
    func respectsObserveOnly() async {
        let wifi = FakeWifi()
        var settings = TestData.settings()
        settings.observeOnly = true
        let outcome = await makeUseCase(wifi).run(state: .leak, settings: settings)
        #expect(outcome == .skippedObserveOnly)
        #expect(await wifi.turnedOffCount == 0)
    }

    @Test("Уведомления об ошибках отключены → эскалация тихая, но выполненная")
    func silentWhenErrorNotificationsOff() async {
        let wifi = FakeWifi()
        let notifications = FakeNotifications()
        var settings = TestData.settings()
        settings.notifyErrors = false
        let outcome = await makeUseCase(wifi, notifications: notifications)
            .run(state: .leak, settings: settings)
        #expect(outcome == .escalated)
        #expect(await notifications.presented.isEmpty)
    }

    @Test("Сбой самой эскалации попадает в журнал")
    func escalationFailureIsJournaled() async {
        struct Boom: Error {}
        let wifi = FakeWifi()
        await wifi.failNext(Boom())
        let journal = FakeJournal()
        let outcome = await makeUseCase(wifi, journal: journal)
            .run(state: .leak, settings: TestData.settings())

        if case .failed = outcome {} else { Issue.record("ожидался failed") }
        let errors = await journal.events.filter { $0.kind.category == .error }
        #expect(errors.count == 1)
    }
}

@Suite("SyncRuleGroups")
struct SyncRuleGroupsTests {
    @Test("Список групп приходит вместе с версией helper")
    func syncsGroups() async {
        let gateway = FakeRuleGroupGateway(groups: ["VPN down": false, "Блок рекламы": true])
        let outcome = await SyncRuleGroups(gateway: gateway, journal: FakeJournal(),
                                           clock: ImmediateClock()).run()
        guard case .synced(let groups, let version) = outcome else {
            Issue.record("ожидался synced")
            return
        }
        #expect(groups.count == 2)
        #expect(version == "1.0")
    }

    @Test("Ошибка helper попадает в журнал")
    func failureIsJournaled() async {
        let gateway = FakeRuleGroupGateway()
        await gateway.failList(with: .unparsableModel("bad json"))
        let journal = FakeJournal()
        let outcome = await SyncRuleGroups(gateway: gateway, journal: journal,
                                           clock: ImmediateClock()).run()
        #expect(outcome == .failed(.unparsableModel("bad json")))
        #expect(await journal.events.count == 1)
    }
}
