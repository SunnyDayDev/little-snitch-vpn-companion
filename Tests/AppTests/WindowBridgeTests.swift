import AppKit
import Testing

@Suite("Мост окна — события AppKit", .serialized)
@MainActor
struct WindowBridgeTests {
    @Test("Окно утилиты на текущей сцене сохраняет Mission Control и обычный уровень")
    func stageManagerBehavior() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.primary, .canJoinAllSpaces, .managed, .fullScreenNone]
        let coordinator = WindowCoordinator(setDockPresence: { _ in true }, activate: {})
        window.contentView = MainWindowObserver(id: .settings, coordinator: coordinator, onClose: {})
        #expect(window.collectionBehavior.contains(.auxiliary))
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        #expect(!window.collectionBehavior.contains(.primary))
        #expect(!window.collectionBehavior.contains(.canJoinAllApplications))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.managed))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(!window.collectionBehavior.contains(.transient))
        #expect(window.level == .normal)
        window.contentView = nil
    }

    @Test("Только закрытие завершает онбординг; чужие окна не учитываются")
    func closeNotification() {
        _ = NSApplication.shared
        var presence: [Bool] = []
        var closes = 0
        let coordinator = WindowCoordinator(setDockPresence: {
            presence.append($0)
            return true
        }, activate: {})
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = MainWindowObserver(id: .onboarding, coordinator: coordinator) { closes += 1 }
        window.contentView = observer
        let center = NotificationCenter.default
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(coordinator.hasOpenWindows)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        center.post(name: NSApplication.didHideNotification, object: NSApplication.shared)
        #expect(closes == 0)
        #expect(presence == [true])
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        center.post(name: NSWindow.willCloseNotification, object: other)
        #expect(closes == 0)
        center.post(name: NSWindow.willCloseNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(closes == 1)
        #expect(presence == [true, false])
        #expect(!coordinator.hasOpenWindows)
        window.contentView = nil
    }

    @Test("Поповер передаёт своё окно, не регистрируя основную сцену")
    func popoverReference() {
        _ = NSApplication.shared
        let reference = PopoverWindowReference()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = PopoverWindowObserver(reference: reference)
        #expect(reference.window === window)
        window.contentView = nil
        #expect(reference.window == nil)
    }

    @Test("События прежнего моста не подменяют новый экземпляр сцены")
    func obsoleteBridge() {
        _ = NSApplication.shared
        let coordinator = WindowCoordinator(setDockPresence: { _ in true }, activate: {})
        let old = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let current = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        old.isReleasedWhenClosed = false
        current.isReleasedWhenClosed = false
        old.contentView = MainWindowObserver(id: .settings, coordinator: coordinator, onClose: {})
        current.contentView = MainWindowObserver(id: .settings, coordinator: coordinator, onClose: {})
        let center = NotificationCenter.default
        center.post(name: NSWindow.didBecomeKeyNotification, object: current)
        center.post(name: NSWindow.didBecomeKeyNotification, object: old)
        center.post(name: NSWindow.willCloseNotification, object: old)
        #expect(coordinator.hasOpenWindows)
        center.post(name: NSWindow.willCloseNotification, object: current)
        #expect(!coordinator.hasOpenWindows)
        old.contentView = nil
        current.contentView = nil
    }
}
