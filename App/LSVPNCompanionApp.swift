import AppKit
import SwiftUI

enum WindowID {
    static let settings = "settings"
    static let journal = "journal"
    static let onboarding = "onboarding"
}

@main
struct LSVPNCompanionApp: App {
    @State private var model = CompositionRoot.makeModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover().environment(model)
        } label: {
            // Мониторинг запускается отсюда, а не из поповера: содержимое
            // поповера создаётся лишь при открытии, а лейбл живёт с запуска.
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        // Заголовки окон — как в макетах `design/app.pen`.
        Window("Little Snitch VPN Companion — Настройки", id: WindowID.settings) {
            SettingsWindow().environment(model)
        }
        .windowResizability(.contentSize)

        Window("Журнал", id: WindowID.journal) {
            JournalWindow().environment(model)
        }
        .windowResizability(.contentSize)

        Window("Добро пожаловать", id: WindowID.onboarding) {
            OnboardingWindow().environment(model)
        }
        .windowResizability(.contentSize)
        // В макете у окна онбординга только светофор, без строки заголовка.
        .windowStyle(.hiddenTitleBar)
    }
}

/// Делегат приложения существует ради одного: перехватить завершение
/// (⌘Q, logout, выключение) и в строгом режиме успеть закрыть группы
/// до смерти процесса.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Модель попадает сюда из `.task` лейбла строки меню: делегат создаётся
    /// системой раньше, чем SwiftUI построит `@State`-модель, поэтому передать
    /// её через инициализатор нельзя. Ссылка слабая — делегат живёт дольше
    /// сцен и не должен продлевать модели жизнь.
    static weak var model: AppModel?

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

/// Иконка строки меню — состояние (§7.5): template-щит, danger-акцент при
/// утечке, warn — когда трафик закрыт без утечки.
@MainActor
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
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
                await model.start()
                if model.isOnboardingPresented {
                    openWindow(id: WindowID.onboarding)
                }
            }
    }

    /// Danger — утечка; warn — закрыто/неопределённость (Checking, Paused и
    /// Offline в строгом режиме); монохром — Protected и Offline в реактивном.
    /// Под observeOnly warn для Offline врал бы: группы не тронуты (ФТ-10).
    private var accent: Color {
        switch model.snapshot.state {
        case .leak: DSColor.danger
        case .checking, .paused: DSColor.warn
        case .offline: model.settings.protectionMode == .strict
            && !model.settings.observeOnly ? DSColor.warn : Color.primary
        case .protected: Color.primary
        }
    }
}
