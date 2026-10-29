import AppKit
import SwiftUI

@main
struct LSVPNCompanionApp: App {
    @State private var model = CompositionRoot.makeModel()
    @State private var windows = WindowCoordinator.live()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover().environment(model).environment(windows)
        } label: {
            // Мониторинг запускается отсюда, а не из поповера: содержимое
            // поповера создаётся лишь при открытии, а лейбл живёт с запуска.
            MenuBarLabel().environment(model).environment(windows)
        }
        .menuBarExtraStyle(.window)

        // Заголовки окон — как в макетах `design/app.pen`.
        Window("Little Snitch VPN Companion — Настройки", id: WindowID.settings.rawValue) {
            SettingsWindow().environment(model)
                .background(MainWindowReader(id: .settings, coordinator: windows))
        }
        .windowResizability(.contentSize)

        Window("Журнал", id: WindowID.journal.rawValue) {
            JournalWindow().environment(model)
                .background(MainWindowReader(id: .journal, coordinator: windows))
        }
        .windowResizability(.contentSize)

        Window("Добро пожаловать", id: WindowID.onboarding.rawValue) {
            OnboardingWindow().environment(model)
                .background(MainWindowReader(id: .onboarding, coordinator: windows,
                                             onClose: model.finishOnboarding))
        }
        .windowResizability(.contentSize)
        // В макете у окна онбординга только светофор, без строки заголовка.
        .windowStyle(.hiddenTitleBar)
    }
}

/// Делегат возвращает окна из Dock и перехватывает завершение процесса,
/// чтобы в строгом режиме успеть закрыть группы до выхода.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Модель попадает сюда из `.task` лейбла строки меню: делегат создаётся
    /// системой раньше, чем SwiftUI построит `@State`-модель, поэтому передать
    /// её через инициализатор нельзя. Ссылка слабая — делегат живёт дольше
    /// сцен и не должен продлевать модели жизнь.
    static weak var model: AppModel?
    static weak var windows: WindowCoordinator?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Координатор восстанавливает существующее окно; стандартная обработка
        // нужна только при отсутствии зарегистрированных основных окон.
        !(Self.windows?.reopenFromDock() ?? false)
    }

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task {
            // Гонка с таймаутом: зависший helper не должен блокировать выход
            // навсегда — страховкой остаётся dead-man's switch в helper.
            // 8 с: холодный XPC-вызов стоит до 6 с (таймаут gateway), и
            // бюджет обязан вмещать хотя бы один такой + сам CLI.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.prepareForTermination() }
                group.addTask { try? await Task.sleep(for: .seconds(8)) }
                _ = await group.next()
                group.cancelAll()
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Иконка строки меню — сводное состояние детекторов (§7.5): template-щит,
/// danger-акцент при утечке, warn — когда трафик закрыт без утечки.
@MainActor
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowCoordinator.self) private var windows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Символы берём из статус-иконки дизайн-системы: второй список имён
        // разошёлся бы с ней (так и вышло — на паузе иконка пропадала).
        Image(systemName: DSStatusIcon.State(model.snapshot.state).symbolName)
            .foregroundStyle(accent)
            .task {
                // Делегат узнаёт о модели там же, где стартует мониторинг:
                // лейбл — единственная вью, живущая с запуска приложения.
                AppDelegate.model = model
                AppDelegate.windows = windows
                await model.start()
                if model.isOnboardingPresented {
                    windows.open(.onboarding) { openWindow(id: $0.rawValue) }
                }
            }
    }

    /// Иконка — по сводному состоянию детекторов. Danger — утечка у любого;
    /// warn — закрыто/неопределённость (Checking, Paused и Offline, если
    /// среди детекторов в Offline есть строгий); монохром — Protected и
    /// Offline только реактивных. Под observeOnly warn для Offline врал бы:
    /// группы не тронуты (ФТ-10).
    private var accent: Color {
        let overall = model.snapshot.overall
        return switch overall.state {
        case .leak: DSColor.danger
        case .checking, .paused: DSColor.warn
        case .offline: overall.hasStrictClosed
            && !model.settings.observeOnly ? DSColor.warn : Color.primary
        case .protected: Color.primary
        }
    }
}
