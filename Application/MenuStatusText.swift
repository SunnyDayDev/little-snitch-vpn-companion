/// Тексты меню без зависимости от SwiftUI: шапка и строки используют
/// только основания принятого состояния, а не последний сырой trace.
struct MenuStatusText {
    enum Tone { case ok, warn, danger }
    struct Banner {
        let style: Tone
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
                return "\(enabled.count) \(Self.plural(enabled.count, one: "детектор", few: "детектора", many: "детекторов")) · "
                    + (enabled.count == 2 ? "оба защищены" : "все защищены")
            }
            guard let focus else { return "" }
            return Self.protectionText(for: focus)
        case .leak:
            guard let focus, case .leak(let ip, let diagnosis) = focus.explanation else {
                return ""
            }
            let reason = switch diagnosis {
            case .forbiddenServer: "цепочка вышла напрямую с запрещённого сервера"
            case .directRuIP: "полный обход VPN: прямой IP сети"
            case .foreignEgress: "egress не соответствует правилам защиты"
            }
            return "\(ip.text) — \(reason)"
        case .offline:
            let reason: String
            switch focus?.explanation {
            case .offline(.noNetwork): reason = "нет сети"
            case .offline(.beaconUnavailable): reason = "маяк недоступен"
            default: reason = "нет результата проверки"
            }
            return reason + (isEnforcingStrict ? " — трафик закрыт"
                : " — состояние групп не меняется")
        case .checking:
            return "ждём подтверждения защиты"
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
                          title: "Закрыто — нет подтверждения защиты",
                          message: "Строгий режим: группы остаются включены. "
                              + "Откроется после подтверждения защиты." + heldSuffix)
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
        if settings.observeOnly { return "Режим наблюдения" }
        return culpritGroups.isEmpty
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
        let owner = isMulti
            ? (culpritGroups.count == 1
                ? "Группа «\(culpritGroups[0])» включена детектором «\(focus.name)». "
                : "Группы включены детектором «\(focus.name)». ")
            : ""
        return owner + "Блокировка снимется после подтверждения защиты."
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

    static func protectionText(for detector: DetectorSnapshot) -> String {
        guard case .protected(let evidence) = detector.explanation else { return "" }
        return [evidence.expectedIP?.text, evidence.warp.map { "warp=\($0.rawValue)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func detectorState(for detector: DetectorSnapshot, observeOnly: Bool = false) -> String {
        guard detector.isEnabled else { return "выключен" }
        switch detector.state {
        case .protected:
            let evidence = protectionText(for: detector)
            return evidence.isEmpty ? "защищён" : "защищён · " + evidence
        case .leak:
            guard case .leak(let ip, _) = detector.explanation else { return "утечка" }
            return "утечка · " + ip.text
        case .checking: return "проверка · ждём вердикт"
        case .offline:
            return detector.mode == .strict && !observeOnly ? "офлайн · закрыто" : "офлайн"
        case .paused: return "пауза"
        }
    }

    static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return many }
        switch count % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}
