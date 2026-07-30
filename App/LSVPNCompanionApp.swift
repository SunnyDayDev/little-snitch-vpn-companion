import SwiftUI

enum WindowID {
    static let settings = "settings"
    static let journal = "journal"
    static let onboarding = "onboarding"
}

@main
struct LSVPNCompanionApp: App {
    @State private var model = CompositionRoot.makeModel()

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

/// Иконка строки меню — состояние (§7.5): монохромный template-щит,
/// красный акцент только при утечке.
@MainActor
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Символы берём из статус-иконки дизайн-системы: второй список имён
        // разошёлся бы с ней (так и вышло — на паузе иконка пропадала).
        Image(systemName: DSStatusIcon.State(model.snapshot.state).symbolName)
            .foregroundStyle(model.snapshot.state == .leak ? DSColor.danger : Color.primary)
            .task {
                await model.start()
                if model.isOnboardingPresented {
                    openWindow(id: WindowID.onboarding)
                }
            }
    }
}
