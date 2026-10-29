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

            if !model.snapshot.detectors.isEmpty {
                DetectorsBlock(detectors: model.snapshot.detectors)
                    .padding(DSMetrics.Popover.detectorsPadding)
            }

            VStack(spacing: DSMetrics.Popover.infoRowGap) {
                DSInfoRow(label: "Проверка", value: presentation.lastCheck)
                DSInfoRow(label: "Группы LS",
                          value: presentation.groupsValue,
                          valueColor: presentation.groupsValueColor)
                DSInfoRow(label: "Сеть", value: presentation.network)
                // Та же строка статуса, что в настройках, без ссылки; во время
                // операции над регистрацией тон предупреждающий, а не ошибка.
                if !model.diagnosis.isReady {
                    DSInfoRow(label: diagnosisLabel,
                              value: model.diagnosis.title,
                              valueColor: diagnosisColor)
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

    private var statusIconState: DSStatusIcon.State {
        DSStatusIcon.State(model.snapshot.state)
    }

    private var presentation: StatusPresentation {
        StatusPresentation(snapshot: model.snapshot, settings: model.settings)
    }
}

/// Блок «Детекторы» (макеты поповеров): строка на детектор — иконка
/// состояния, имя, состояние с egress; выключенные приглушены.
@MainActor
private struct DetectorsBlock: View {
    let detectors: [DetectorSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Детекторы")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(DSColor.textTertiary)
            ForEach(detectors) { detector in
                // В одну строку, как в макете, пока имя и egress помещаются;
                // иначе состояние уходит под имя — ни имя, ни адрес не режутся
                // ради другого.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DSSpacing.sm) {
                        icon(for: detector)
                        name(of: detector).fixedSize()
                        Spacer(minLength: DSSpacing.sm)
                        state(of: detector).fixedSize()
                    }
                    HStack(alignment: .top, spacing: DSSpacing.sm) {
                        icon(for: detector)
                        VStack(alignment: .leading, spacing: 1) {
                            name(of: detector)
                            state(of: detector).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func icon(for detector: DetectorSnapshot) -> some View {
        let state = DSStatusIcon.State(detector.state)
        return Image(systemName: detector.isEnabled
            ? state.symbolName : DSSymbol.resolve("shield.slash"))
            .font(.system(size: 12))
            .foregroundStyle(detector.isEnabled ? state.color : DSColor.muted)
            .frame(width: 14, height: 14)
    }

    private func name(of detector: DetectorSnapshot) -> some View {
        Text(detector.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(detector.isEnabled ? DSColor.textPrimary : DSColor.textSecondary)
            .lineLimit(1)
    }

    private func state(of detector: DetectorSnapshot) -> some View {
        Text(DetectorPresentation.stateText(for: detector))
            .font(DSFont.caption)
            .foregroundStyle(DetectorPresentation.stateColor(for: detector))
            .lineLimit(1)
    }
}

/// Тексты поповера, вынесенные из вью: их удобно менять и читать отдельно
/// от вёрстки. Шапка и иконка — по сводному состоянию, баннер — о
/// детекторе-виновнике.
struct StatusPresentation {
    struct Banner {
        let style: DSStatusBanner.Style
        let title: String
        let message: String
    }

    let snapshot: MonitoringSnapshot
    let settings: AppSettings

    private var enabled: [DetectorSnapshot] { snapshot.enabledDetectors }
    /// С одним детектором тексты прежние; имя появляется, когда путей несколько.
    private var isMulti: Bool { enabled.count > 1 }
    private var focus: DetectorSnapshot? { snapshot.focus }

    /// Строгий детектор-виновник реально закрывает свои группы. Под
    /// observeOnly утверждать «трафик закрыт» нельзя — группы не тронуты
    /// (ФТ-10 побеждает).
    private var isEnforcingStrict: Bool {
        focus?.mode == .strict && !settings.observeOnly
    }

    /// На паузе закрыто, если среди включённых есть строгий.
    private var pauseCloses: Bool {
        enabled.contains { $0.mode == .strict } && !settings.observeOnly
    }

    private var hasNoDetectors: Bool {
        !snapshot.overall.hasEnabledDetectors && snapshot.state != .paused
    }

    var title: String {
        if hasNoDetectors { return "Детекторов нет" }
        let base = switch snapshot.state {
        case .protected: "Защищено"
        case .leak: "Утечка"
        case .offline: "Офлайн"
        case .checking: "Проверка"
        case .paused: "Пауза"
        }
        guard isMulti, snapshot.state != .protected, snapshot.state != .paused,
              let culprit = focus else { return base }
        return "\(base): \(culprit.name)"
    }

    var subtitle: String {
        if hasNoDetectors { return "включите или добавьте детектор в настройках — следить не за чем" }
        switch snapshot.state {
        case .protected:
            if isMulti {
                return "\(enabled.count) \(DetectorPresentation.plural(enabled.count, one: "детектор", few: "детектора", many: "детекторов")) · "
                    + (enabled.count == 2 ? "оба защищены" : "все защищены")
            }
            guard let trace = snapshot.trace else { return "egress в цепочке VPN" }
            var parts = ["egress \(trace.ip.text)", "warp=\(trace.warp.rawValue)"]
            if let colo = trace.colo { parts.append(colo) }
            return parts.joined(separator: " · ")
        case .leak:
            guard let trace = snapshot.trace else { return "трафик идёт напрямую" }
            guard let diagnosis = snapshot.diagnosis, isMulti else {
                return "egress \(trace.ip.text) — трафик идёт напрямую"
            }
            return "egress \(trace.ip.text) — \(MonitoringCoordinator.describe(diagnosis))"
        case .offline:
            return isEnforcingStrict
                ? "сети нет — трафик закрыт"
                : "маяк недоступен — состояние групп не меняется"
        case .checking:
            return "сеть сменилась — ждём подтверждения VPN"
        case .paused:
            return pauseCloses
                ? "мониторинг на паузе — трафик закрыт"
                : "мониторинг остановлен вручную"
        }
    }

    var banner: Banner? {
        if hasNoDetectors { return nil }
        switch snapshot.state {
        case .protected:
            return isMulti
                ? Banner(style: .ok,
                         title: "Все пути работают",
                         message: "Foreign-трафик каждого детектора уходит ожидаемым путём. "
                             + "Группы Little Snitch выключены.")
                : Banner(style: .ok,
                         title: "Цепочка работает",
                         message: "Foreign-трафик уходит через VPN. Группы Little Snitch выключены.")
        case .leak:
            return Banner(style: .danger, title: blockedTitle, message: leakMessage)
        // Checking возникает только у строгих детекторов; проверка на
        // `isEnforcingStrict` — на случай отставшего снапшота при
        // переключении strict→reactive и ради честности под observeOnly.
        case .checking where isEnforcingStrict:
            return Banner(style: .warn,
                          title: "Закрыто — ждём подтверждения VPN",
                          message: "Строгий режим: группы включены, пока проба не подтвердит цепочку."
                              + heldSuffix)
        case .offline where isEnforcingStrict:
            return Banner(style: .warn,
                          title: "Закрыто: сети нет",
                          message: "Строгий режим: группы остаются включены. "
                              + "Откроется после возвращения сети и подтверждения VPN." + heldSuffix)
        case .paused where pauseCloses:
            return Banner(style: .warn,
                          title: "Пауза: трафик закрыт",
                          message: "Строгий режим: группы остаются включены, "
                              + "пока мониторинг не возобновится и VPN не подтвердится.")
        // Реактивные Offline и Paused групп не трогают — баннер не нужен,
        // контекст даёт подзаголовок.
        case .offline, .paused, .checking:
            return nil
        }
    }

    /// Группы детектора-виновника, фактически включённые сейчас.
    private var culpritGroups: [String] {
        guard let focus else { return [] }
        let active = Set(snapshot.activeLeakGroups)
        let held = focus.groups.filter(active.contains)
        return held.isEmpty ? focus.groups : held
    }

    /// «Детектор «X» держит закрытыми: G» — только когда детекторов несколько.
    private var heldSuffix: String {
        guard isMulti, let focus, !culpritGroups.isEmpty else { return "" }
        return " Детектор «\(focus.name)» держит закрытыми: \(culpritGroups.joined(separator: ", "))."
    }

    private var blockedTitle: String {
        culpritGroups.isEmpty
            ? "Группы не выбраны"
            : "Заблокированы: \(culpritGroups.joined(separator: ", "))"
    }

    private var leakMessage: String {
        guard !settings.observeOnly else {
            return "Режим наблюдения: группы Little Snitch не тронуты."
        }
        guard let focus, !culpritGroups.isEmpty else {
            return "Выберите группы в настройках детектора — иначе блокировать нечего."
        }
        let reason = switch snapshot.diagnosis {
        case .forbiddenServer(let ip): "Цепочка вышла напрямую с сервера \(ip.text). "
        case .directRuIP: "Полный обход VPN: трафик идёт с прямого IP сети. "
        case .foreignEgress, .none: ""
        }
        let owner = isMulti
            ? (culpritGroups.count == 1
                ? "Группа «\(culpritGroups[0])» включена детектором «\(focus.name)». "
                : "Группы включены детектором «\(focus.name)». ")
            : ""
        return reason + owner + "Снимется автоматически, когда egress вернётся в цепочку."
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

    /// Danger — только при утечке любого детектора. Группы, включённые без
    /// утечки (Checking, Offline/Paused строгих), — warn: закрыто намеренно,
    /// не авария.
    var groupsValueColor: Color {
        if enabled.contains(where: { $0.state == .leak }) { return DSColor.danger }
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
