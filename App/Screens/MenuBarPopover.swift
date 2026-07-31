import SwiftUI

/// Поповер строки меню (§7.1 SPEC.md), ширина 340 pt.
@MainActor
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Секции имеют свои горизонтальные отступы (макет: шапка и инфо 16,
        // баннер 12, пункты меню 8) — общий паддинг на весь поповер их бы сбил.
        VStack(alignment: .leading, spacing: 0) {
            DSStatusHeader(state: statusIconState,
                           title: presentation.title,
                           subtitle: presentation.subtitle)
                .padding(DSMetrics.Popover.headerPadding)

            if let banner = presentation.banner {
                DSStatusBanner(style: banner.style,
                               title: banner.title,
                               message: banner.message)
                    .padding(DSMetrics.Popover.bannerPadding)
            }

            VStack(spacing: DSMetrics.Popover.infoRowGap) {
                DSInfoRow(label: "Проверка", value: presentation.lastCheck)
                DSInfoRow(label: "Группы LS",
                          value: presentation.groupsValue,
                          valueColor: presentation.groupsValueColor)
                DSInfoRow(label: "Сеть", value: presentation.network)
                if !model.diagnosis.isReady {
                    DSInfoRow(label: diagnosisLabel,
                              value: model.diagnosis.title,
                              valueColor: DSColor.danger)
                }
            }
            .padding(DSMetrics.Popover.infoPadding)

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
                    openWindow(id: WindowID.journal)
                    model.activateApp()
                }
                DSMenuItem(icon: "gearshape", title: "Настройки…") {
                    openWindow(id: WindowID.settings)
                    model.activateApp()
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
    }

    /// Метка строки зависит от того, кто виноват: helper или сам Little Snitch.
    private var diagnosisLabel: String {
        switch model.diagnosis {
        case .littleSnitchNotAuthorized: "Little Snitch"
        case .ready, .helperNotInstalled, .failing: "Helper"
        }
    }

    private var statusIconState: DSStatusIcon.State {
        DSStatusIcon.State(model.snapshot.state)
    }

    private var presentation: StatusPresentation {
        StatusPresentation(snapshot: model.snapshot, settings: model.settings)
    }
}

/// Тексты поповера, вынесенные из вью: их удобно менять и читать отдельно
/// от вёрстки.
struct StatusPresentation {
    struct Banner {
        let style: DSStatusBanner.Style
        let title: String
        let message: String
    }

    let snapshot: MonitoringSnapshot
    let settings: AppSettings

    /// Режимо-зависимые тексты ниже читают режим прямо из настроек — как и
    /// прочие подписи (observeOnly, leakGroups).
    private var isStrict: Bool { settings.protectionMode == .strict }

    /// Строгий режим реально закрывает группы. Под observeOnly утверждать
    /// «трафик закрыт» нельзя — группы не тронуты (ФТ-10 побеждает).
    private var isEnforcingStrict: Bool { isStrict && !settings.observeOnly }

    var title: String {
        switch snapshot.state {
        case .protected: "Защищено"
        case .leak: "Утечка"
        case .offline: "Офлайн"
        case .checking: "Проверка"
        case .paused: "Пауза"
        }
    }

    var subtitle: String {
        switch snapshot.state {
        case .protected:
            guard let trace = snapshot.trace else { return "egress в цепочке VPN" }
            var parts = ["egress \(trace.ip.text)", "warp=\(trace.warp.rawValue)"]
            if let colo = trace.colo { parts.append(colo) }
            return parts.joined(separator: " · ")
        case .leak:
            guard let trace = snapshot.trace else { return "трафик идёт напрямую" }
            return "egress \(trace.ip.text) — трафик идёт напрямую"
        case .offline:
            return isEnforcingStrict
                ? "сети нет — трафик закрыт"
                : "маяк недоступен — состояние групп не меняется"
        case .checking:
            return "сеть сменилась — ждём подтверждения VPN"
        case .paused:
            return isEnforcingStrict
                ? "мониторинг на паузе — трафик закрыт"
                : "мониторинг остановлен вручную"
        }
    }

    var banner: Banner? {
        switch snapshot.state {
        case .protected:
            Banner(style: .ok,
                   title: "Цепочка работает",
                   message: "Foreign-трафик уходит через VPN. Группы Little Snitch выключены.")
        case .leak:
            Banner(style: .danger,
                   title: blockedTitle,
                   message: leakMessage)
        // Checking возникает только в строгом режиме; проверка на
        // `isEnforcingStrict` — на случай отставшего снапшота при
        // переключении strict→reactive и ради честности под observeOnly.
        case .checking where isEnforcingStrict:
            Banner(style: .warn,
                   title: "Закрыто — ждём подтверждения VPN",
                   message: "Строгий режим: группы включены, пока проба не подтвердит цепочку.")
        case .offline where isEnforcingStrict:
            Banner(style: .warn,
                   title: "Закрыто: сети нет",
                   message: "Строгий режим: группы остаются включены. "
                       + "Откроется после возвращения сети и подтверждения VPN.")
        case .paused where isEnforcingStrict:
            Banner(style: .warn,
                   title: "Пауза: трафик закрыт",
                   message: "Строгий режим: группы остаются включены, "
                       + "пока мониторинг не возобновится и VPN не подтвердится.")
        // В реактивном режиме Offline и Paused групп не трогают — баннер
        // не нужен, контекст даёт подзаголовок.
        case .offline, .paused, .checking:
            nil
        }
    }

    private var blockedTitle: String {
        settings.leakGroups.isEmpty
            ? "Группы не выбраны"
            : "Заблокированы: \(settings.leakGroups.joined(separator: ", "))"
    }

    private var leakMessage: String {
        guard !settings.observeOnly else {
            return "Режим наблюдения: группы Little Snitch не тронуты."
        }
        guard !settings.leakGroups.isEmpty else {
            return "Выберите группы во вкладке «Группы» — иначе блокировать нечего."
        }
        let reason = switch snapshot.diagnosis {
        case .forbiddenServer(let ip): "Цепочка вышла напрямую с сервера \(ip.text). "
        case .directRuIP: "Полный обход VPN: трафик идёт с прямого IP сети. "
        case .foreignEgress, .none: ""
        }
        return reason + "Снимется автоматически, когда egress вернётся в цепочку."
    }

    var groupsValue: String {
        if settings.observeOnly { return "режим наблюдения" }
        // Не врём «выключены», если reconcile не дошёл: блок мог остаться.
        guard snapshot.groupsStateKnown else { return "состояние неизвестно" }
        guard !snapshot.activeLeakGroups.isEmpty else { return "выключены" }
        return snapshot.activeLeakGroups.count == 1
            ? "включена «\(snapshot.activeLeakGroups[0])»"
            : "включены: \(snapshot.activeLeakGroups.joined(separator: ", "))"
    }

    /// Danger — только при утечке. Группы, включённые без утечки (Checking,
    /// Offline/Paused в строгом режиме), — warn: закрыто намеренно, не авария.
    var groupsValueColor: Color {
        if snapshot.state == .leak { return DSColor.danger }
        if !snapshot.activeLeakGroups.isEmpty { return DSColor.warn }
        return DSColor.textPrimary
    }

    var lastCheck: String {
        guard let lastCheck = snapshot.lastCheck else { return "ещё не было" }
        let age = Date().timeIntervalSince1970 - lastCheck.secondsSinceEpoch
        let trigger = snapshot.lastTrigger.map(JournalFormatting.trigger) ?? "проба"
        return "\(RelativeAge.text(age)) · \(trigger)"
    }

    var network: String {
        guard let path = snapshot.path else { return "—" }
        guard path.isSatisfied else { return "нет сети" }
        return path.gateway.map { "\(path.interfaceDescription) · \($0)" }
            ?? path.interfaceDescription
    }
}

enum RelativeAge {
    static func text(_ seconds: Double) -> String {
        switch seconds {
        case ..<2: "только что"
        case ..<60: "\(Int(seconds)) с назад"
        case ..<3600: "\(Int(seconds / 60)) мин назад"
        default: "\(Int(seconds / 3600)) ч назад"
        }
    }
}
