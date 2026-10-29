import SwiftUI

/// Поповер строки меню (§7.1 SPEC.md), ширина 340 pt.
@MainActor
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowCoordinator.self) private var windows
    @State private var popover = PopoverWindowReference()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Секции имеют свои горизонтальные отступы (макет: шапка и инфо 16,
        // баннер 12, пункты меню 8) — общий паддинг на весь поповер их бы сбил.
        VStack(alignment: .leading, spacing: 0) {
            MenuStatusPanel(snapshot: model.snapshot, settings: model.settings,
                            diagnosisLabel: model.diagnosis.isReady ? nil : diagnosisLabel,
                            diagnosisText: model.diagnosis.title, diagnosisColor: diagnosisColor)

            DSSeparator()

            VStack(spacing: DSMetrics.Popover.menuItemGap) {
                DSMenuItem(icon: "arrow.clockwise", title: "Проверить сейчас") {
                    Task { await model.probeNow() }
                }
                DSMenuItem(icon: model.snapshot.state == .paused ? "play" : "pause",
                           title: model.snapshot.state == .paused
                               ? "Возобновить" : "Пауза мониторинга") {
                    Task { await model.togglePause() }
                }
                DSMenuItem(icon: "list.bullet.rectangle", title: "Журнал…") {
                    windows.open(.journal, from: popover.window) { openWindow(id: $0.rawValue) }
                }
                DSMenuItem(icon: "gearshape", title: "Настройки…") {
                    windows.open(.settings, from: popover.window) { openWindow(id: $0.rawValue) }
                }
            }
            .padding(DSMetrics.Popover.menuPadding)

            DSSeparator()

            DSMenuItem(icon: "power", title: "Завершить", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .padding(DSMetrics.Popover.footerPadding)
        }
        .frame(width: DSMetrics.Popover.width)
        .background(DSColor.bgPopover)
        .background(PopoverWindowReader(reference: popover))
    }

    /// Метка строки зависит от того, кто виноват: helper или сам Little Snitch.
    private var diagnosisLabel: String {
        switch model.diagnosis {
        case .littleSnitchNotAuthorized: "Little Snitch"
        case .ready, .helper, .failing: "Helper"
        }
    }

    private var diagnosisColor: Color {
        switch model.diagnosis.tone {
        case .normal, .warning: DSColor.warn
        case .danger: DSColor.danger
        case .ok: DSColor.ok
        }
    }

}
