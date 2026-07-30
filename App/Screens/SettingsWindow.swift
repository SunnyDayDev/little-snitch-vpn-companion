import SwiftUI

/// Окно настроек (§7.2–7.4 SPEC.md), 720 pt, вкладки в стиле System Settings.
@MainActor
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Иконки — по макету: слайдеры, активность, щит.
            DSTabBar(items: [
                DSTabBar.Item(icon: "slider.horizontal.3", label: "Общие"),
                DSTabBar.Item(icon: "waveform.path.ecg", label: "Детектор"),
                DSTabBar.Item(icon: "shield", label: "Группы"),
            ], selection: $selectedTab)
            .padding(DSMetrics.Settings.tabBarPadding)
            .background(DSColor.bgWindow)

            DSSeparator()

            ScrollView {
                Group {
                    switch selectedTab {
                    case 0: GeneralSettingsTab()
                    case 1: DetectorSettingsTab()
                    default: RuleGroupsTab()
                    }
                }
                .padding(DSMetrics.Settings.contentPadding)
            }
            .background(DSColor.bgWindow)
        }
        .frame(width: DSMetrics.Settings.width, height: DSMetrics.Settings.height)
        .task { await model.refreshRuleGroups() }
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
                SettingsRow {
                    DSSettingRow(title: "Привилегированный helper",
                                 subtitle: helperSubtitle) {
                        DSSecondaryButton("Переустановить…") {
                            Task { await model.reinstallHelper() }
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

    /// Показываем один и тот же диагноз, что и поповер: раньше настройки
    /// уверяли «подключён · root», пока поповер писал «недоступен».
    private var helperSubtitle: String {
        let version = model.helperVersion.map { "v\($0) · " } ?? ""
        return version + model.diagnosis.title
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { newValue in model.update { $0[keyPath: keyPath] = newValue } })
    }
}

// MARK: - Детектор

@MainActor
private struct DetectorSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var editingList: IPListEditor.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.Settings.cardRowGap) {
            SettingsCard(caption: "Интервалы") {
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
            Text("""
                Смена сети всегда вызывает немедленную пробу. Утечка фиксируется только \
                после подтверждения второй пробой через 2–3 секунды.
                """)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textTertiary)

            SettingsCard(caption: "Маяк") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Основной") {
                        Text("cloudflare.com/cdn-cgi/trace")
                            .font(DSFont.mono)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Резервный") {
                        Text("1.1.1.1/cdn-cgi/trace")
                            .font(DSFont.mono)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }

            SettingsCard(caption: "Ожидаемый egress") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Критерий защиты") {
                        DSStatusChip(text: "warp=on", style: .ok)
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Дополнительные IP",
                                 subtitle: expectedSubtitle) {
                        DSSecondaryButton("Изменить…") { editingList = .expected }
                    }
                }
            }

            SettingsCard(caption: "Запрещённый egress") {
                SettingsRow(isFirst: true) {
                    DSSettingRow(title: "Серверы инфраструктуры",
                                 subtitle: forbiddenSubtitle) {
                        HStack(spacing: DSSpacing.sm) {
                            // Пустой список описан подписью строки — одинокий
                            // «0» рядом с кнопкой только мешает.
                            if !model.settings.forbiddenEgressIPs.isEmpty {
                                Text("\(model.settings.forbiddenEgressIPs.count)")
                                    .font(DSFont.valueLabel)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            DSSecondaryButton("Изменить…") { editingList = .forbidden }
                        }
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "Прямой РУ-IP", subtitle: ruBeaconSubtitle) {
                        Text(model.snapshot.directRuIP?.text ?? "—")
                            .font(DSFont.mono)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                SettingsRow {
                    DSSettingRow(title: "РУ-маяк") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.settings.ruBeaconURL)
                            Text(model.settings.ruBeaconFallbackURL)
                        }
                        .font(DSFont.mono)
                        .foregroundStyle(DSColor.textSecondary)
                    }
                }
            }
        }
        .sheet(item: $editingList) { kind in
            IPListEditor(kind: kind)
        }
    }

    /// Список пуст по умолчанию: выходные узлы у каждого свои.
    private var forbiddenSubtitle: String {
        model.settings.forbiddenEgressIPs.isEmpty
            ? "список пуст — добавь свои выходные узлы: egress с них означает, что цепочка вышла напрямую"
            : "egress с этих IP = цепочка вышла напрямую, минуя WARP"
    }

    private var expectedSubtitle: String {
        model.settings.expectedIPs.isEmpty
            ? "EXPECTED_IPS — пусто; пригодится для egress своего WireGuard"
            : model.settings.expectedIPs.joined(separator: ", ")
    }

    private var ruBeaconSubtitle: String {
        guard let updated = model.snapshot.directRuIPUpdated else {
            return "автоопределение — ответа пока нет"
        }
        let age = Date().timeIntervalSince1970 - updated.secondsSinceEpoch
        let host = URL(string: model.settings.ruBeaconURL)?.host() ?? "РУ-маяк"
        return "\(host) · \(RelativeAge.text(age))"
    }

    private func seconds(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Int> {
        Binding(get: { Int(model.settings[keyPath: keyPath]) },
                set: { newValue in model.update { $0[keyPath: keyPath] = Double(newValue) } })
    }
}

// MARK: - Группы

@MainActor
private struct RuleGroupsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("""
                Какие rule groups Little Snitch включать при каждом состоянии. \
                Сами группы и их правила создаются и редактируются в Little Snitch.
                """)
                .font(DSFont.body)
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                HStack {
                    Text("Группа в Little Snitch")
                    Spacer()
                    Text("Включать при утечке")
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
                                       subtitle: group.enabled ? "включена в LS" : "выключена в LS",
                                       isOn: binding(for: group.name))
                            .padding(.horizontal, DSMetrics.Table.horizontalPadding)
                            .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
                    }
                }
            }
            .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.lg))

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

    /// Статус helper в футере: иконка + подпись, цвет по состоянию (макет
    /// «Настройки — Группы»).
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

    private var statusColor: Color {
        switch model.diagnosis {
        case .ready: DSColor.ok
        case .helperNotInstalled: DSColor.warn
        case .littleSnitchNotAuthorized, .failing: DSColor.danger
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(get: { model.settings.leakGroups.contains(name) },
                set: { model.toggleLeakGroup(name, isOn: $0) })
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

/// Редактор списка IP: строка на адрес, невалидные подсвечиваются и
/// не сохраняются.
@MainActor
struct IPListEditor: View {
    enum Kind: String, Identifiable {
        case expected, forbidden
        var id: String { rawValue }

        var title: String {
            switch self {
            case .expected: "Дополнительные ожидаемые IP"
            case .forbidden: "Серверы инфраструктуры (запрещённый egress)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text(kind.title)
                .font(DSFont.windowTitle)
                .foregroundStyle(DSColor.textPrimary)
            Text("По одному адресу в строке. Строки после # — комментарии.")
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
        switch kind {
        case .expected: model.settings.expectedIPs
        case .forbidden: model.settings.forbiddenEgressIPs
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
        model.update { settings in
            switch kind {
            case .expected: settings.expectedIPs = valid
            case .forbidden: settings.forbiddenEgressIPs = valid
            }
        }
    }
}
