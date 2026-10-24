import SwiftUI

/// Окно настроек (§7.2–7.4 SPEC.md), 720 pt, вкладки в стиле System Settings:
/// Общие и Детекторы. Детали детектора открываются на месте списка.
@MainActor
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = 0
    @State private var openedDetector: DetectorID?

    var body: some View {
        VStack(spacing: 0) {
            // Иконки — по макету: слайдеры и активность.
            DSTabBar(items: [
                DSTabBar.Item(icon: "slider.horizontal.3", label: "Общие"),
                DSTabBar.Item(icon: "waveform.path.ecg", label: "Детекторы"),
            ], selection: $selectedTab)
            .padding(DSMetrics.Settings.tabBarPadding)
            .background(DSColor.bgWindow)

            DSSeparator()

            ScrollView {
                Group {
                    switch selectedTab {
                    case 0:
                        GeneralSettingsTab()
                    default:
                        if let id = openedDetector, model.settings.detector(id) != nil {
                            DetectorDetailView(id: id) { openedDetector = $0 }
                        } else {
                            DetectorsTab { openedDetector = $0 }
                        }
                    }
                }
                .padding(DSMetrics.Settings.contentPadding)
            }
            .background(DSColor.bgWindow)
        }
        .frame(width: DSMetrics.Settings.width, height: DSMetrics.Settings.height)
        .task { await model.refreshRuleGroups() }
        .onChange(of: selectedTab) { _, _ in openedDetector = nil }
    }
}

// MARK: - Общие

@MainActor
private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.Settings.cardRowGap) {
            SettingsCard(caption: "Основное") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Запускать при входе в систему") {
                        DSToggle(isOn: binding(\.launchAtLogin))
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Мониторинг",
                                 subtitle: "следить за egress и применять группы автоматически") {
                        DSToggle(isOn: binding(\.monitoringEnabled))
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Режим наблюдения",
                                 subtitle: "только уведомления — группы Little Snitch не трогать") {
                        DSToggle(isOn: binding(\.observeOnly))
                    }
                }
            }

            SettingsCard(caption: "Отказоустойчивость") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Выключать Wi-Fi при отказе helper",
                                 subtitle: "эскалация: утечка подтверждена, а littlesnitch недоступен") {
                        DSToggle(isOn: binding(\.escalationEnabled))
                    }
                }
                // Кнопка и подпись — из единого представления состояния helper
                // (спека helper-lifecycle): «Установить…», «Переустановить…» или
                // «Удалить…», неактивная кнопка во время операции, ссылка на
                // Системные настройки в подписи при ожидании одобрения.
                SettingsRow {
                    let presentation = model.helperPresentation
                    DSSettingRow(title: "Привилегированный helper",
                                 subtitle: presentation.showsApprovalLink
                                     ? presentation.statusText + " ·"
                                     : presentation.statusText,
                                 subtitleTone: presentation.tone.dsTone,
                                 subtitleLink: presentation.showsApprovalLink
                                     ? DSSubtitleLink(title: HelperPresentation.approvalLinkTitle) {
                                         Task { await model.openHelperApprovalSettings() }
                                     }
                                     : nil) {
                        DSSecondaryButton(presentation.buttonTitle,
                                          isEnabled: presentation.isButtonEnabled) {
                            Task { await model.performHelperAction() }
                        }
                    }
                }
                // Отдельная строка появляется только при запрете со стороны LS:
                // helper тут исправен, и чинить надо в настройках Little Snitch.
                if model.diagnosis == .littleSnitchNotAuthorized {
                    SettingsRow {
                        DSSettingRow(
                            title: "Little Snitch не пускает свой CLI",
                            subtitle: "включи доступ в Little Snitch → Настройки → Безопасность") {
                            DSSecondaryButton("Открыть Little Snitch…") {
                                model.openLittleSnitch()
                            }
                        }
                    }
                }
            }

            SettingsCard(caption: "Уведомления") {
                // Без системного разрешения тумблеры ниже ничего не значат:
                // запросы молча отбрасываются.
                if !model.notificationAuthorization.isUsable {
                    SettingsRow(isFirst: true) {
                        DSSettingRow(
                            title: "Уведомления \(model.notificationAuthorization.description)",
                            subtitle: "о переходах и ошибках сообщать будет нечем") {
                            DSSecondaryButton("Разрешить…") {
                                Task { _ = await model.requestNotificationAuthorization() }
                            }
                        }
                    }
                }
                SettingsRow(isFirst: model.notificationAuthorization.isUsable) {
                    DSSettingRow(title: "Утечка и восстановление") {
                        DSToggle(isOn: binding(\.notifyTransitions))
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Ошибки helper и Little Snitch") {
                        DSToggle(isOn: binding(\.notifyErrors))
                    }
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }
}

// MARK: - Детекторы: список

@MainActor
private struct DetectorsTab: View {
    @Environment(AppModel.self) private var model
    let open: (DetectorID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.Settings.cardRowGap) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                SettingsCard(caption: "Детекторы") {
                    if model.settings.detectors.isEmpty {
                        SettingsRow(isFirst: true) {
                            Text("Детекторов нет — мониторинг работает вхолостую. "
                                + "Добавьте детектор, чтобы следить за путём трафика.")
                                .font(DSFont.secondary)
                                .foregroundStyle(DSColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(Array(model.settings.detectors.enumerated()), id: \.element.id) { index, config in
                        if index > 0 { DSSeparator() }
                        row(for: config)
                    }
                }
                HStack(spacing: DSMetrics.Settings.tabBarGap) {
                    DSSecondaryButton("Добавить детектор…") {
                        open(model.addDetector())
                    }
                    Text(DetectorPresentation.counter(
                        total: model.settings.detectors.count,
                        enabled: model.settings.enabledDetectors.count))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textTertiary)
                    Spacer()
                }
            }

            SettingsCard(caption: "Общее для всех детекторов") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Heartbeat растяжки",
                                 subtitle: "крошечный запрос по постоянному TLS-соединению") {
                        DSStepperField(value: seconds(\.heartbeatSeconds), range: 5...600, unit: "с")
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Плановая свежая проба",
                                 subtitle: "ground truth новым соединением") {
                        DSStepperField(value: seconds(\.probeSeconds), range: 10...3600, unit: "с")
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Таймаут пробы") {
                        DSStepperField(value: seconds(\.probeTimeoutSeconds), range: 1...30, unit: "с")
                    }
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: DSIconSize.xs - 2))
                Text("""
                    Смена сети всегда вызывает немедленную пробу. Утечка фиксируется только \
                    после подтверждения второй пробой через 2–3 секунды.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DSFont.caption)
            .foregroundStyle(DSColor.textTertiary)
            .padding(.horizontal, 2)

            SettingsCard(caption: "Прямой IP сети") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Прямой РУ-IP", subtitle: ruBeaconSubtitle) {
                        Text(model.snapshot.directRuIP?.text ?? "—")
                            .font(DSFont.mono)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "РУ-маяк",
                                 subtitle: "домен обязан быть в зоне .ru — иначе запрос уйдёт через VPN") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Self.withoutScheme(model.settings.ruBeaconURL))
                            Text(Self.withoutScheme(model.settings.ruBeaconFallbackURL))
                        }
                        .font(DSFont.mono)
                        .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
        }
    }

    private func row(for config: DetectorConfig) -> some View {
        let detector = model.snapshot.detector(config.id)
            ?? DetectorSnapshot(id: config.id, name: config.name, isEnabled: config.isEnabled,
                                mode: config.protectionMode, proxy: config.proxy,
                                groups: config.groups)
        let chip = DetectorPresentation.chip(for: detector)
        return DSDetectorRow(
            state: DSStatusIcon.State(detector.state),
            isEnabled: config.isEnabled,
            name: config.name,
            subtitle: DetectorPresentation.subtitle(proxy: config.proxy,
                                                    mode: config.protectionMode,
                                                    groups: config.groups),
            chipText: chip.text,
            chipStyle: chip.style) {
            open(config.id)
        }
    }

    private var ruBeaconSubtitle: String {
        let shared = "попадает в запрещённые всех детекторов"
        guard let updated = model.snapshot.directRuIPUpdated else {
            return "\(shared) · ответа пока нет"
        }
        let age = Date().timeIntervalSince1970 - updated.secondsSinceEpoch
        let host = URL(string: model.settings.ruBeaconURL)?.host() ?? "РУ-маяк"
        return "\(shared) · \(host) · \(RelativeAge.text(age))"
    }

    static func withoutScheme(_ url: String) -> String {
        for scheme in ["https://", "http://"] where url.lowercased().hasPrefix(scheme) {
            return String(url.dropFirst(scheme.count))
        }
        return url
    }

    private func seconds(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Int> {
        Binding(get: { Int(model.settings[keyPath: keyPath]) },
                set: { newValue in model.update { $0[keyPath: keyPath] = Double(newValue) } })
    }
}

// MARK: - Детекторы: детали

@MainActor
private struct DetectorDetailView: View {
    @Environment(AppModel.self) private var model
    let id: DetectorID
    /// `nil` — вернуться к списку; иначе открыть детали другого детектора.
    let navigate: (DetectorID?) -> Void
    @State private var editingList: IPListEditor.Kind?
    @State private var isConfirmingDelete = false

    var body: some View {
        if let config = model.settings.detector(id) {
            content(config)
        }
    }

    private func content(_ config: DetectorConfig) -> some View {
        VStack(alignment: .leading, spacing: DSMetrics.Settings.cardRowGap) {
            header(config)

            SettingsCard(caption: "Детектор") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Название") {
                        DSTextField(value: config.name,
                                    validate: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { name in
                            model.updateDetector(id) { $0.name = name }
                        }
                    }
                }
                SettingsRow {
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text("Режим защиты")
                            .font(DSFont.windowTitle)
                            .foregroundStyle(DSColor.textPrimary)
                        DSSegmentedControl(
                            titles: ["Блокировать при утечке", "Открывать только при VPN"],
                            selection: modeSelection)
                        Text(modeCaption(config.protectionMode))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // observeOnly побеждает строгий режим (D7): без этой
                        // строки казалось бы, что трафик закрыт, хотя группы
                        // не трогаются.
                        if model.settings.observeOnly, config.protectionMode == .strict {
                            Text("режим наблюдения активен: группы не трогаются")
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsCard(caption: "Путь") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Прокси", subtitle: "детектор ходит к маяку через этот прокси") {
                        DSSegmentedControl(titles: ["Нет", "HTTP CONNECT", "SOCKS5"],
                                           selection: proxySelection)
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Адрес прокси",
                                 subtitle: "хост и порт · логин и пароль — не в первой версии") {
                        DSTextField(value: config.proxy.address,
                                    placeholder: "203.0.113.5:1080",
                                    isMonospaced: true,
                                    width: 200,
                                    isEnabled: !config.proxy.isDirect,
                                    validate: { ProxyConfig.parseAddress($0) != nil }) { raw in
                            guard let parsed = ProxyConfig.parseAddress(raw) else { return }
                            model.updateDetector(id) {
                                $0.proxy.host = parsed.host
                                $0.proxy.port = parsed.port
                            }
                        }
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Растяжка",
                                 subtitle: config.proxy.isDirect
                                     ? "постоянное соединение к маяку; обрыв — немедленная проба"
                                     : "постоянное соединение к маяку через тот же прокси; обрыв — немедленная проба") {
                        DSToggle(isOn: detectorBinding(\.tripwireEnabled))
                    }
                }
            }

            SettingsCard(caption: "Маяк") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Основной") {
                        DSTextField(value: config.beacon.primaryURL, isMonospaced: true, width: 300,
                                    validate: BeaconConfig.isValidURL) { url in
                            model.updateDetector(id) { $0.beacon.primaryURL = url }
                        }
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Резервный",
                                 subtitle: "тем же путём; пусто — без резервного маяка") {
                        DSTextField(value: config.beacon.fallbackURL ?? "",
                                    placeholder: "не задан",
                                    isMonospaced: true, width: 300,
                                    validate: { $0.isEmpty || BeaconConfig.isValidURL($0) }) { url in
                            model.updateDetector(id) { $0.beacon.fallbackURL = url.isEmpty ? nil : url }
                        }
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Формат ответа",
                                 subtitle: "cdn-cgi/trace отдаёт любой домен за Cloudflare; "
                                     + "голый IP — сервисы вида «какой у меня IP»") {
                        DSSegmentedControl(titles: ["cdn-cgi/trace", "голый IP"],
                                           selection: formatSelection)
                    }
                }
            }

            SettingsCard(caption: "Ожидаемый egress") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "warp=on считается защитой",
                                 subtitle: warpSubtitle(config)) {
                        DSToggle(isOn: detectorBinding(\.warpCountsAsProtection))
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Ожидаемые IP", subtitle: expectedSubtitle(config)) {
                        countAndEdit(config.expectedIPs.count) { editingList = .expected }
                    }
                }
            }

            SettingsCard(caption: "Запрещённый egress") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Запрещённые IP", subtitle: forbiddenSubtitle(config)) {
                        countAndEdit(config.forbiddenEgressIPs.count) { editingList = .forbidden }
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Прямой IP сети",
                                 subtitle: "общий для всех детекторов, приходит от РУ-маяка") {
                        Text(model.snapshot.directRuIP?.text ?? "—")
                            .font(DSFont.mono)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }

            groupsSection(config)

            HStack(spacing: DSMetrics.Settings.tabBarGap) {
                DSSecondaryButton("Удалить детектор…", titleColor: DSColor.danger) {
                    isConfirmingDelete = true
                }
                Spacer()
                DSSecondaryButton("Дублировать") {
                    model.duplicateDetector(id)
                    navigate(nil)
                }
            }
            .padding(.top, DSSpacing.sm)
        }
        .sheet(item: $editingList) { kind in
            IPListEditor(detector: id, kind: kind)
        }
        .confirmationDialog("Удалить детектор «\(config.name)»?",
                            isPresented: $isConfirmingDelete) {
            Button("Удалить", role: .destructive) {
                model.deleteDetector(id)
                navigate(nil)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(deleteConsequences(config))
        }
    }

    // MARK: Шапка

    private func header(_ config: DetectorConfig) -> some View {
        let detector = model.snapshot.detector(id)
            ?? DetectorSnapshot(id: id, name: config.name, isEnabled: config.isEnabled,
                                mode: config.protectionMode, proxy: config.proxy,
                                groups: config.groups)
        let chip = DetectorPresentation.chip(for: detector)
        return HStack(spacing: DSMetrics.Settings.tabBarGap) {
            Button { navigate(nil) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Детекторы")
                        .font(DSFont.secondary)
                }
                .foregroundStyle(DSColor.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(config.name)
                .font(DSFont.popoverTitle)
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSStatusChip(text: chip.text, style: chip.style)
            DSToggle(isOn: detectorBinding(\.isEnabled))
        }
        .padding(.horizontal, 2)
        .padding(.bottom, DSSpacing.xs)
    }

    // MARK: Группы

    private func groupsSection(_ config: DetectorConfig) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            SettingsCard(caption: "Группы") {
                HStack {
                    Text("Группа в Little Snitch")
                    Spacer()
                    Text("Включать этим детектором")
                }
                .font(DSFont.sectionCaption)
                .textCase(.uppercase)
                .foregroundStyle(DSColor.textTertiary)
                .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                .padding(.vertical, DSMetrics.Table.headerVerticalPadding)

                DSSeparator()

                if model.ruleGroups.isEmpty {
                    Text(model.groupsError ?? "Список пуст — обновите его из Little Snitch")
                        .font(DSFont.secondary)
                        .foregroundStyle(model.groupsError == nil
                            ? DSColor.textSecondary : DSColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                        .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
                } else {
                    ForEach(Array(model.ruleGroups.enumerated()), id: \.element.name) { index, group in
                        if index > 0 { DSSeparator() }
                        DSRuleGroupRow(name: group.name,
                                       subtitle: subtitle(for: group),
                                       isOn: groupBinding(group.name))
                            .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                            .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
                    }
                }
            }

            // Подсказка §13: дефолтной группы нет в LS — её нужно создать.
            if config.id == .primary, config.groups.isEmpty, !model.ruleGroups.isEmpty,
               !model.ruleGroups.contains(where: { $0.name == AppSettings.defaultLeakGroupName }) {
                Text("""
                    Создайте в Little Snitch группу «\(AppSettings.defaultLeakGroupName)» с запретами \
                    для foreign-приложений и отметьте её здесь.
                    """)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Предупреждение о самозапирании (§15): в строгом режиме включённая
            // группа с браузером не даст пройти captive portal и поднять VPN.
            Text("""
                Не включайте в группы браузер и VPN-клиент — ручной выход из \
                закрытого трафика делается в самом Little Snitch.
                """)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DSMetrics.Settings.tabBarGap) {
                DSSecondaryButton("Обновить список из LS") {
                    Task { await model.refreshRuleGroups() }
                }
                if let updated = model.groupsUpdatedAt {
                    Text("обновлено \(RelativeAge.text(Date().timeIntervalSince(updated)))")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textTertiary)
                }
                Spacer()
                helperStatusLabel
            }
        }
    }

    /// Состояние в LS, подписка и «также в …»: у группы, входящей в другие
    /// детекторы, причина её закрытости видна прямо здесь.
    private func subtitle(for group: RuleGroup) -> String {
        let state = group.enabled ? "включена в LS" : "выключена в LS"
        var parts = [group.kind == .remote ? "подписка · \(state)" : state]
        let others = model.settings.owners(of: group.name, excluding: id, enabledOnly: false)
        if !others.isEmpty {
            parts.append("также в " + others.map { "«\($0.name)»" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Статус helper в футере: иконка + подпись, цвет по состоянию.
    private var helperStatusLabel: some View {
        HStack(spacing: DSSpacing.xs + 1) {
            Image(systemName: model.diagnosis.isReady
                ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: DSIconSize.xs))
                .foregroundStyle(statusColor)
            Text(model.diagnosis.isReady
                ? "helper подключён · root"
                : model.diagnosis.title)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Цвет по тону диагноза: «в работе» и «не установлен» — обычный, ожидание
    /// одобрения и устаревший демон — warn, запрет CLI и ошибки — danger.
    private var statusColor: Color {
        switch model.diagnosis.tone {
        case .normal: DSColor.textTertiary
        case .warning: DSColor.warn
        case .danger: DSColor.danger
        case .ok: DSColor.ok
        }
    }

    // MARK: Подписи

    private func modeCaption(_ mode: ProtectionMode) -> String {
        switch mode {
        case .reactive:
            "группы этого детектора включаются только при подтверждённой утечке; "
                + "офлайн и проверка их не трогают"
        case .strict:
            "трафик по этому пути открыт только при подтверждённом VPN; пауза, "
                + "выход и сбой приложения закрывают его группы"
        }
    }

    private func warpSubtitle(_ config: DetectorConfig) -> String {
        config.warpCountsAsProtection
            ? "ответ маяка с warp=on — признак защиты"
            : "выключено: защиту определяют только ожидаемые IP — warp=on означал бы чужой путь"
    }

    private func expectedSubtitle(_ config: DetectorConfig) -> String {
        config.expectedIPs.isEmpty
            ? "EXPECTED_IPS — пусто; пригодится для egress своего WireGuard или выхода прокси"
            : config.expectedIPs.joined(separator: ", ")
    }

    /// Список пуст по умолчанию: выходные узлы у каждого свои.
    private func forbiddenSubtitle(_ config: DetectorConfig) -> String {
        config.forbiddenEgressIPs.isEmpty
            ? "список пуст — добавь свои выходные узлы или сам прокси-сервер: egress с них означает, что путь вышел напрямую"
            : config.forbiddenEgressIPs.joined(separator: ", ")
                + " — egress с этих IP значит, что путь вышел напрямую"
    }

    /// Последствия удаления для групп: эксклюзивные откроются, общие
    /// останутся под управлением других детекторов.
    private func deleteConsequences(_ config: DetectorConfig) -> String {
        let exclusive = config.groups.filter { model.settings.owners(of: $0, excluding: id).isEmpty }
        let shared = config.groups.filter { !model.settings.owners(of: $0, excluding: id).isEmpty }
        var lines: [String] = []
        if config.groups.isEmpty {
            lines.append("У детектора нет групп — Little Snitch не изменится.")
        }
        if !exclusive.isEmpty, config.isEnabled {
            lines.append("Группы \(exclusive.map { "«\($0)»" }.joined(separator: ", ")) будут выключены: "
                + "трафик по ним откроется.")
        }
        if !shared.isEmpty {
            lines.append("Группы \(shared.map { "«\($0)»" }.joined(separator: ", ")) останутся "
                + "под управлением других детекторов.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: Привязки

    private func countAndEdit(_ count: Int, action: @escaping () -> Void) -> some View {
        HStack(spacing: DSSpacing.sm) {
            // Пустой список описан подписью строки — одинокий «0» рядом с
            // кнопкой только мешает.
            if count > 0 {
                Text("\(count)")
                    .font(DSFont.valueLabel)
                    .foregroundStyle(DSColor.textSecondary)
            }
            DSSecondaryButton("Изменить…", action: action)
        }
    }

    private func detectorBinding(_ keyPath: WritableKeyPath<DetectorConfig, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings.detector(id)?[keyPath: keyPath] ?? false },
                set: { newValue in model.updateDetector(id) { $0[keyPath: keyPath] = newValue } })
    }

    private func groupBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { model.settings.detector(id)?.groups.contains(name) ?? false },
                set: { model.toggleGroup(name, in: id, isOn: $0) })
    }

    /// Сегмент-контрол работает индексами, а настройка — enum: 0 — реактивный,
    /// 1 — строгий (порядок сегментов в макете).
    private var modeSelection: Binding<Int> {
        Binding(get: { model.settings.detector(id)?.protectionMode == .strict ? 1 : 0 },
                set: { newValue in
                    model.updateDetector(id) { $0.protectionMode = newValue == 1 ? .strict : .reactive }
                })
    }

    private static let proxyKinds: [ProxyConfig.Kind] = [.direct, .httpConnect, .socks5]

    private var proxySelection: Binding<Int> {
        Binding(get: {
                    let kind = model.settings.detector(id)?.proxy.kind ?? .direct
                    return Self.proxyKinds.firstIndex(of: kind) ?? 0
                },
                set: { newValue in
                    model.updateDetector(id) { $0.proxy.kind = Self.proxyKinds[newValue] }
                })
    }

    private var formatSelection: Binding<Int> {
        Binding(get: { model.settings.detector(id)?.beacon.format == .plainIP ? 1 : 0 },
                set: { newValue in
                    model.updateDetector(id) { $0.beacon.format = newValue == 1 ? .plainIP : .cdnCgiTrace }
                })
    }
}

// MARK: - Общие части

/// Карточка-секция настроек. Строки получают вертикальный паддинг каждая
/// (макет: 10–14 внутри строки) — иначе они слипаются в один блок, как это
/// и вышло с общим паддингом на всю карточку.
@MainActor
private struct SettingsCard<Content: View>: View {
    let caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(caption)
                .font(DSFont.sectionCaption)
                .textCase(.uppercase)
                .foregroundStyle(DSColor.textTertiary)
            VStack(spacing: 0) { content() }
                .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.lg))
        }
    }
}

/// Обёртка строки настройки: собственные отступы и разделитель сверху.
@MainActor
private struct SettingsRow<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { DSSeparator() }
            content()
                .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
        }
    }
}

/// Редактор списка IP детектора: строка на адрес, невалидные подсвечиваются
/// и не сохраняются.
@MainActor
struct IPListEditor: View {
    enum Kind: String, Identifiable {
        case expected, forbidden
        var id: String { rawValue }

        var title: String {
            switch self {
            case .expected: "Ожидаемые IP (защищённый egress)"
            case .forbidden: "Запрещённые IP (серверы инфраструктуры, сам прокси)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let detector: DetectorID
    let kind: Kind
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(kind.title)
                .font(DSFont.windowTitle)
                .foregroundStyle(DSColor.textPrimary)
            Text("Детектор «\(model.settings.detector(detector)?.name ?? "")». "
                + "По одному адресу в строке. Строки после # — комментарии.")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textTertiary)

            TextEditor(text: $text)
                .font(DSFont.mono)
                .frame(height: 220)
                .padding(DSSpacing.sm)
                .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.sm))

            if !invalidLines.isEmpty {
                Text("Не распознаны как IP: \(invalidLines.joined(separator: ", "))")
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.danger)
            }

            HStack {
                Spacer()
                DSSecondaryButton("Отмена") { dismiss() }
                DSPrimaryButton("Сохранить") {
                    save()
                    dismiss()
                }
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 460)
        .background(DSColor.bgWindow)
        .onAppear { text = currentList.joined(separator: "\n") }
    }

    private var currentList: [String] {
        guard let config = model.settings.detector(detector) else { return [] }
        return switch kind {
        case .expected: config.expectedIPs
        case .forbidden: config.forbiddenEgressIPs
        }
    }

    private var parsedLines: [(raw: String, isValid: Bool)] {
        text.split(whereSeparator: \.isNewline)
            .map { line in
                String(line.prefix(while: { $0 != "#" })).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .map { ($0, IPAddress($0) != nil) }
    }

    private var invalidLines: [String] {
        parsedLines.filter { !$0.isValid }.map(\.raw)
    }

    private func save() {
        let valid = parsedLines.filter(\.isValid).map(\.raw)
        model.updateDetector(detector) { config in
            switch kind {
            case .expected: config.expectedIPs = valid
            case .forbidden: config.forbiddenEgressIPs = valid
            }
        }
    }
}
