import Observation

enum WindowID: String, CaseIterable {
    case settings, journal, onboarding
}

/// Узкая граница оконной системы: тесты не меняют Dock и фокус пользователя.
@MainActor
protocol CompanionWindow: AnyObject {
    var isPresented: Bool { get }
    func showCompanionWindow()
    func hideCompanionWindow()
}

/// Открытое окно остаётся открытым при сворачивании и скрытии приложения.
/// Только явное закрытие снимает его присутствие; поповер сюда не входит.
@MainActor
@Observable
final class WindowCoordinator {
    private struct Entry {
        weak var window: (any CompanionWindow)?
        var isOpen: Bool
    }

    private var entries: [WindowID: Entry] = [:]
    private var pending: Set<WindowID> = []
    private var lastActive: WindowID?
    private var appliedDockPresence: Bool
    private var isApplyingPresence = false
    private var requestedFocus: WindowID?
    private var presentationGeneration = 0
    private let setDockPresence: (Bool) -> Bool
    private let activate: () -> Void
    private let enqueue: (@escaping @MainActor () -> Void) -> Void

    init(initialDockPresence: Bool = false,
         setDockPresence: @escaping (Bool) -> Bool,
         activate: @escaping () -> Void,
         enqueue: @escaping (@escaping @MainActor () -> Void) -> Void = { $0() }) {
        appliedDockPresence = initialDockPresence
        self.setDockPresence = setDockPresence
        self.activate = activate
        self.enqueue = enqueue
    }

    var hasOpenWindows: Bool {
        entries.values.contains { $0.isOpen && $0.window != nil }
    }

    func register(_ window: any CompanionWindow, as id: WindowID) {
        if entries[id]?.window !== window {
            entries[id] = Entry(window: window, isOpen: window.isPresented)
        }
        reconcilePresence()
    }

    func didFinishAttaching(_ window: any CompanionWindow, as id: WindowID) {
        guard entries[id]?.window === window else { return }
        if pending.contains(id) {
            finishOpening(window, as: id)
        }
    }

    func didBecomeKey(_ window: any CompanionWindow, as id: WindowID) {
        guard entries[id]?.window === window else { return }
        entries[id]?.isOpen = true
        lastActive = id
        // openWindow может повторно показать сохранённый экземпляр сцены,
        // не создавая новый мост. Событие окна завершает и этот переход.
        if pending.contains(id) {
            finishOpening(window, as: id)
        } else {
            reconcilePresence()
        }
    }

    @discardableResult
    func didClose(_ window: any CompanionWindow, as id: WindowID) -> Bool {
        guard entries[id]?.window === window, entries[id]?.isOpen == true else {
            return false
        }
        entries[id]?.isOpen = false
        pending.remove(id)
        if lastActive == id { lastActive = nil }
        reconcilePresence()
        return true
    }

    func open(_ id: WindowID, from popover: (any CompanionWindow)? = nil,
              openScene: @escaping (WindowID) -> Void) {
        requestedFocus = id
        popover?.hideCompanionWindow()
        if let entry = entries[id], entry.isOpen, let window = entry.window {
            reconcilePresence()
            present(window, as: id)
            return
        }
        let isNewRequest = pending.insert(id).inserted
        reconcilePresence()
        guard isNewRequest else { return }
        // Сначала заканчиваем закрытие поповера и запрашиваем активацию.
        // Не ждём didBecomeActive: без окна macOS может активировать приложение
        // лишь после нажатия Dock, и такое ожидание блокирует само открытие.
        enqueue { [weak self] in
            guard let self, self.pending.contains(id) else { return }
            self.activate()
            openScene(id)
            // Сохранённая SwiftUI-сцена не обязана заново присоединить мост.
            self.enqueue { [weak self] in
                guard let self, self.pending.contains(id),
                      let window = self.entries[id]?.window else { return }
                self.finishOpening(window, as: id)
            }
        }
    }

    /// Возврат из Dock не создаёт сцен. При нескольких окнах выбирается
    /// последнее активное, затем первое открытое в стабильном порядке ролей.
    @discardableResult
    func reopenFromDock() -> Bool {
        let candidates = lastActive.map { [$0] } ?? []
        for id in candidates + WindowID.allCases {
            guard let entry = entries[id], entry.isOpen, let window = entry.window else {
                continue
            }
            reconcilePresence()
            requestedFocus = id
            present(window, as: id)
            return true
        }
        return false
    }

    private func finishOpening(_ window: any CompanionWindow, as id: WindowID) {
        pending.remove(id)
        entries[id]?.isOpen = true
        reconcilePresence()
        present(window, as: id)
    }

    private func present(_ window: any CompanionWindow, as id: WindowID) {
        guard requestedFocus == id else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        // Закрытие MenuBarExtra и смена activationPolicy должны закончить
        // свой проход очереди, иначе возврат фокуса из поповера перебивает нас.
        enqueue { [weak self, weak window] in
            guard let self, let window,
                  self.presentationGeneration == generation,
                  self.requestedFocus == id,
                  self.entries[id]?.window === window,
                  self.entries[id]?.isOpen == true else { return }
            self.lastActive = id
            self.activate()
            window.showCompanionWindow()
        }
    }

    private func reconcilePresence() {
        let desired = hasOpenWindows || !pending.isEmpty
        guard !isApplyingPresence, desired != appliedDockPresence else { return }
        // AppKit может синхронно прислать оконное событие из смены политики.
        isApplyingPresence = true
        // Неуспешный запрос не кешируется: следующее оконное событие повторит его.
        let succeeded = setDockPresence(desired)
        if succeeded { appliedDockPresence = desired }
        isApplyingPresence = false
        if succeeded, desired != (hasOpenWindows || !pending.isEmpty) {
            reconcilePresence()
        }
    }
}
