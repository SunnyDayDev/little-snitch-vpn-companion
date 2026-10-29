import Testing

@MainActor
private final class FakeWindow: CompanionWindow {
    var isPresented = false
    var isMinimized = false
    var isHidden = false
    var shows = 0
    let name: String
    let record: (String) -> Void

    init(_ name: String, record: @escaping (String) -> Void) {
        self.name = name
        self.record = record
    }

    func showCompanionWindow() {
        isPresented = true
        isMinimized = false
        isHidden = false
        shows += 1
        record("show:\(name)")
    }

    func hideCompanionWindow() {
        isPresented = false
        record("hide:\(name)")
    }
}

@MainActor
private final class WindowHarness {
    var events: [String] = []
    var acceptsPolicy = true
    var defersWork = false
    var queued: [@MainActor () -> Void] = []
    lazy var coordinator = WindowCoordinator(
        setDockPresence: { [unowned self] visible in
            events.append(visible ? "dock:on" : "dock:off")
            return acceptsPolicy
        },
        activate: { [unowned self] in events.append("activate") },
        enqueue: { [unowned self] action in
            if defersWork { queued.append(action) } else { action() }
        })

    func drain() {
        while !queued.isEmpty { queued.removeFirst()() }
    }

    func window(_ name: String) -> FakeWindow {
        FakeWindow(name) { [unowned self] in events.append($0) }
    }

    func request(_ id: WindowID, from popover: FakeWindow? = nil) {
        coordinator.open(id, from: popover) { [unowned self] in
            events.append("open:\($0.rawValue)")
        }
    }

    func open(_ id: WindowID) -> FakeWindow {
        let window = window(id.rawValue)
        request(id)
        coordinator.register(window, as: id)
        coordinator.didFinishAttaching(window, as: id)
        return window
    }
}

@Suite("Окна — присутствие в Dock и переходы из меню")
@MainActor
struct WindowCoordinatorTests {
    @Test("Фоновый запуск не показывает Dock; пустой возврат не создаёт окно")
    func backgroundStart() {
        let h = WindowHarness()
        #expect(!h.coordinator.hasOpenWindows)
        #expect(!h.coordinator.reopenFromDock())
        #expect(h.events.isEmpty)
    }

    @Test("Поповер закрывается до показа окна", arguments: [WindowID.settings, .journal])
    func menuTransition(id: WindowID) {
        let h = WindowHarness()
        let popover = h.window("popover")
        popover.isPresented = true
        let window = h.window(id.rawValue)
        h.request(id, from: popover)
        #expect(!popover.isPresented)
        #expect(h.events == ["hide:popover", "dock:on", "activate", "open:\(id.rawValue)"])
        h.coordinator.register(window, as: id)
        h.coordinator.didFinishAttaching(window, as: id)
        #expect(h.events.suffix(2) == ["activate", "show:\(id.rawValue)"])
        #expect(h.coordinator.hasOpenWindows)
        h.coordinator.didClose(window, as: id)
        #expect(h.events.last == "dock:off")
    }

    @Test("Dock сохраняется до закрытия последнего из нескольких окон")
    func multipleWindows() {
        let h = WindowHarness()
        let settings = h.open(.settings)
        let journal = h.open(.journal)
        journal.isMinimized = true
        h.coordinator.didClose(settings, as: .settings)
        #expect(h.coordinator.hasOpenWindows)
        #expect(!h.events.contains("dock:off"))
        h.coordinator.didClose(journal, as: .journal)
        #expect(!h.coordinator.hasOpenWindows)
        #expect(h.events.filter { $0.hasPrefix("dock:") } == ["dock:on", "dock:off"])
    }

    @Test("Повторные события не переключают Dock и не закрывают окно дважды")
    func duplicateEvents() {
        let h = WindowHarness()
        let window = h.open(.settings)
        h.coordinator.register(window, as: .settings)
        h.coordinator.didBecomeKey(window, as: .settings)
        #expect(h.coordinator.didClose(window, as: .settings))
        #expect(!h.coordinator.didClose(window, as: .settings))
        #expect(h.events.filter { $0.hasPrefix("dock:") } == ["dock:on", "dock:off"])
    }

    @Test("Повторное открытие сохранённой SwiftUI сцены после закрытия")
    func reopenSameInstance() {
        let h = WindowHarness()
        let window = h.open(.settings)
        h.coordinator.didClose(window, as: .settings)
        window.isPresented = false
        h.request(.settings)
        // SwiftUI сохранил NSWindow и мост: нового register нет.
        h.coordinator.didBecomeKey(window, as: .settings)
        #expect(h.coordinator.hasOpenWindows)
        #expect(window.shows == 2)
        h.coordinator.didClose(window, as: .settings)
        #expect(h.events.filter { $0.hasPrefix("dock:") }
            == ["dock:on", "dock:off", "dock:on", "dock:off"])
    }

    @Test("Запоздалые события старого экземпляра не затрагивают новое окно")
    func replacedWindow() {
        let h = WindowHarness()
        let old = h.open(.settings)
        let replacement = h.window("replacement")
        replacement.isPresented = true
        h.coordinator.register(replacement, as: .settings)
        h.coordinator.didClose(old, as: .settings)
        h.coordinator.didBecomeKey(old, as: .settings)
        #expect(h.coordinator.hasOpenWindows)
        h.coordinator.reopenFromDock()
        #expect(replacement.shows == 1)
        #expect(old.shows == 1)
    }

    @Test("Ожидающее открытие удерживает Dock после закрытия другого окна")
    func pendingOpening() {
        let h = WindowHarness()
        let settings = h.open(.settings)
        let journal = h.window("journal")
        h.request(.journal)
        h.request(.journal)
        h.coordinator.didClose(settings, as: .settings)
        #expect(!h.events.contains("dock:off"))
        #expect(h.events.filter { $0 == "open:journal" }.count == 1)
        h.coordinator.register(journal, as: .journal)
        h.coordinator.didFinishAttaching(journal, as: .journal)
        #expect(journal.shows == 1)
        h.coordinator.didClose(journal, as: .journal)
        #expect(h.events.last == "dock:off")
    }

    @Test("Неуспешная смена политики повторяется; окно всё равно показывается")
    func rejectedPolicy() {
        let h = WindowHarness()
        h.acceptsPolicy = false
        let window = h.open(.settings)
        #expect(window.shows == 1)
        h.acceptsPolicy = true
        h.coordinator.didBecomeKey(window, as: .settings)
        let attempts = h.events.filter { $0 == "dock:on" }.count
        #expect(attempts >= 2)
        h.coordinator.didBecomeKey(window, as: .settings)
        #expect(h.events.filter { $0 == "dock:on" }.count == attempts)
        h.coordinator.didClose(window, as: .settings)
        #expect(h.events.last == "dock:off")
    }

    @Test("Неуспешное скрытие Dock можно повторить на следующем событии")
    func rejectedDemotion() {
        let h = WindowHarness()
        let window = h.open(.settings)
        h.acceptsPolicy = false
        h.coordinator.didClose(window, as: .settings)
        h.acceptsPolicy = true
        h.coordinator.register(window, as: .settings)
        #expect(h.events.filter { $0 == "dock:off" }.count == 2)
        #expect(!h.coordinator.hasOpenWindows)
    }

    @Test("Повторный выбор восстанавливает существующее окно", arguments: WindowID.allCases)
    func restoreExisting(id: WindowID) {
        let h = WindowHarness()
        let window = h.open(id)
        window.isPresented = false
        window.isHidden = true
        window.isMinimized = true
        h.request(id)
        #expect(window.shows == 2)
        #expect(!window.isHidden && !window.isMinimized)
        #expect(h.events.filter { $0 == "open:\(id.rawValue)" }.count == 1)
        #expect(!h.events.contains("dock:off"))
    }

    @Test("Возврат через Dock восстанавливает последнее активное окно")
    func dockRestore() {
        let h = WindowHarness()
        let settings = h.open(.settings)
        let journal = h.open(.journal)
        h.coordinator.didBecomeKey(settings, as: .settings)
        for window in [settings, journal] {
            window.isHidden = true
            window.isMinimized = true
            window.isPresented = false
        }
        #expect(h.coordinator.reopenFromDock())
        #expect(settings.shows == 2 && journal.shows == 1)
        #expect(!settings.isHidden && !settings.isMinimized)
        h.coordinator.didClose(settings, as: .settings)
        #expect(h.coordinator.reopenFromDock())
        #expect(journal.shows == 2)
        #expect(h.events.filter { $0.hasPrefix("open:") }.count == 2)
    }

    @Test("Сцена, открытая системой без команды меню, учитывается в Dock")
    func externallyOpenedWindow() {
        let h = WindowHarness()
        let window = h.window("settings")
        h.coordinator.register(window, as: .settings)
        #expect(h.events.isEmpty)
        h.coordinator.didBecomeKey(window, as: .settings)
        #expect(h.events == ["dock:on"])
        #expect(h.coordinator.hasOpenWindows)
    }

    @Test("Событие внутри смены политики не вызывает повторный системный запрос")
    func reentrantPolicyChange() {
        var calls: [Bool] = []
        var coordinator: WindowCoordinator!
        let window = FakeWindow("settings", record: { _ in })
        coordinator = WindowCoordinator(setDockPresence: { visible in
            calls.append(visible)
            coordinator.register(window, as: .settings)
            return true
        }, activate: {})
        coordinator.open(.settings) { _ in }
        coordinator.didFinishAttaching(window, as: .settings)
        #expect(calls == [true])
        coordinator.didClose(window, as: .settings)
        #expect(calls == [true, false])
        // Разрываем захват тестового координатора системной подменой.
        coordinator = nil
    }

    @Test("Фокус передаётся после завершения закрытия меню")
    func focusAfterPopoverDismissal() {
        let h = WindowHarness()
        let window = h.open(.settings)
        let popover = h.window("popover")
        h.defersWork = true
        h.events = []
        h.request(.settings, from: popover)
        #expect(h.events == ["hide:popover"])
        // Возврат фокуса прежнему приложению при закрытии меню происходит
        // до следующего прохода очереди, где выполняется наша активация.
        h.events.append("popover-dismissed")
        h.drain()
        #expect(h.events == ["hide:popover", "popover-dismissed", "activate", "show:settings"])
        #expect(window.shows == 2)
    }

    @Test("Повторное открытие не ждёт, что окно само получит фокус")
    func reopenWithoutKeyNotification() {
        let h = WindowHarness()
        let window = h.open(.settings)
        h.coordinator.didClose(window, as: .settings)
        window.isPresented = false
        h.defersWork = true
        h.request(.settings)
        // Нет ни нового viewDidMoveToWindow, ни didBecomeKey.
        h.drain()
        #expect(window.shows == 2)
        #expect(h.coordinator.hasOpenWindows)
    }

    @Test("Отложенный показ не открывает закрытое окно и не крадёт фокус у нового выбора")
    func obsoleteFocusRequest() {
        let h = WindowHarness()
        let settings = h.open(.settings)
        let journal = h.open(.journal)
        h.defersWork = true
        h.events = []
        h.request(.settings)
        h.request(.journal)
        h.drain()
        #expect(settings.shows == 1 && journal.shows == 2)
        #expect(h.events == ["activate", "show:journal"])
        h.request(.journal)
        h.coordinator.didClose(journal, as: .journal)
        h.drain()
        #expect(journal.shows == 2)
    }

    @Test("Открытие из меню не ждёт уведомления активации или нажатия Dock")
    func openWithoutActivationNotification() {
        let h = WindowHarness()
        h.defersWork = true
        let window = h.window("settings")
        h.coordinator.open(.settings, from: h.window("popover")) { id in
            h.events.append("open:settings")
            h.coordinator.register(window, as: id)
            h.coordinator.didFinishAttaching(window, as: id)
        }
        h.drain()
        // Системная подмена только записывает запрос activate и никогда
        // не присылает didBecomeActive. Окно всё равно должно появиться.
        #expect(window.shows == 1)
        #expect(h.events == ["hide:popover", "dock:on", "activate", "open:settings",
                             "activate", "show:settings"])
        #expect(h.coordinator.hasOpenWindows)
    }

    @Test("Существующее скрытое окно показывается без отдельного события активации")
    func restoreWithoutActivationNotification() {
        let h = WindowHarness()
        let window = h.open(.settings)
        window.isPresented = false
        window.isHidden = true
        h.defersWork = true
        h.events = []
        h.request(.settings)
        h.drain()
        #expect(window.shows == 2)
        #expect(!window.isHidden)
        #expect(h.events == ["activate", "show:settings"])
    }
}
