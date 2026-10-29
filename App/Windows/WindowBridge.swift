import AppKit
import SwiftUI

extension NSWindow: CompanionWindow {
    var isPresented: Bool { isVisible || isMiniaturized }

    /// Окна утилиты показываются на текущей сцене Stage Manager рядом
    /// с рабочими окнами, а не проходят через боковую группу приложения.
    func configureCompanionWindow() {
        collectionBehavior.subtract([.primary, .canJoinAllApplications, .canJoinAllSpaces])
        collectionBehavior.formUnion([.auxiliary, .moveToActiveSpace])
    }

    func showCompanionWindow() {
        configureCompanionWindow()
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func hideCompanionWindow() { orderOut(nil) }
}

extension WindowCoordinator {
    static func live() -> WindowCoordinator {
        WindowCoordinator(
            initialDockPresence: NSApplication.shared.activationPolicy() == .regular,
            setDockPresence: { NSApplication.shared.setActivationPolicy($0 ? .regular : .accessory) },
            activate: {
                NSApplication.shared.unhide(nil)
                // Открытие окна — явное действие пользователя; обычный
                // cooperative activate() может оставить приложение позади.
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            enqueue: { action in DispatchQueue.main.async { action() } })
    }
}

/// Получает именно окно своей сцены, не ищет его среди служебных окон SwiftUI.
struct MainWindowReader: NSViewRepresentable {
    let id: WindowID
    let coordinator: WindowCoordinator
    var onClose: () -> Void = {}

    func makeNSView(context: Context) -> MainWindowObserver {
        MainWindowObserver(id: id, coordinator: coordinator, onClose: onClose)
    }

    func updateNSView(_ view: MainWindowObserver, context: Context) {
        view.onClose = onClose
    }
}

@MainActor
final class MainWindowObserver: NSView {
    private let id: WindowID
    private let coordinator: WindowCoordinator
    private weak var observedWindow: NSWindow?
    var onClose: () -> Void

    init(id: WindowID, coordinator: WindowCoordinator, onClose: @escaping () -> Void) {
        self.id = id
        self.coordinator = coordinator
        self.onClose = onClose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        guard let window else { return }
        window.configureCompanionWindow()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(becameKey),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(willClose),
                           name: NSWindow.willCloseNotification, object: window)
        coordinator.register(window, as: id)
        // SwiftUI должен закончить присоединение представления, прежде чем
        // окно получит фокус. Это следующий проход очереди, не таймер.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.coordinator.didFinishAttaching(window, as: self.id)
        }
    }

    @objc private func becameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === observedWindow else { return }
        coordinator.didBecomeKey(window, as: id)
    }

    @objc private func willClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === observedWindow else { return }
        if coordinator.didClose(window, as: id) { onClose() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Слабая ссылка позволяет закрыть поповер до передачи фокуса окну.
@MainActor
final class PopoverWindowReference {
    weak var window: NSWindow?
}

struct PopoverWindowReader: NSViewRepresentable {
    let reference: PopoverWindowReference

    func makeNSView(context: Context) -> PopoverWindowObserver {
        PopoverWindowObserver(reference: reference)
    }

    func updateNSView(_ view: PopoverWindowObserver, context: Context) {}
}

@MainActor
final class PopoverWindowObserver: NSView {
    private let reference: PopoverWindowReference

    init(reference: PopoverWindowReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference.window = window
    }
}
