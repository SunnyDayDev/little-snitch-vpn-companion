import SwiftUI

/// Секция состояния отделена от действий: её можно отрисовать на
/// синтетическом снапшоте без запуска мониторинга, XPC и приложения.
@MainActor
struct MenuStatusPanel: View {
    let snapshot: MonitoringSnapshot
    let settings: AppSettings
    var diagnosisLabel: String? = nil
    var diagnosisText = ""
    var diagnosisColor: Color = DSColor.warn

    private var presentation: StatusPresentation {
        StatusPresentation(snapshot: snapshot, settings: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSStatusHeader(state: DSStatusIcon.State(snapshot.state),
                           title: presentation.title,
                           subtitle: presentation.subtitle)
                .padding(DSMetrics.Popover.headerPadding)

            if let banner = presentation.banner {
                DSStatusBanner(style: banner.style,
                               title: banner.title,
                               message: banner.message)
                    .padding(DSMetrics.Popover.bannerPadding)
            }

            if !snapshot.detectors.isEmpty {
                DetectorsBlock(detectors: snapshot.detectors, observeOnly: settings.observeOnly)
                    .padding(DSMetrics.Popover.detectorsPadding)
            }

            VStack(spacing: DSMetrics.Popover.infoRowGap) {
                DSInfoRow(label: "Проверка", value: presentation.lastCheck)
                DSInfoRow(label: "Группы LS",
                          value: presentation.groupsValue,
                          valueColor: presentation.groupsValueColor)
                // Та же строка статуса, что в настройках, без ссылки; во время
                // операции над регистрацией тон предупреждающий, а не ошибка.
                if let diagnosisLabel {
                    DSInfoRow(label: diagnosisLabel,
                              value: diagnosisText,
                              valueColor: diagnosisColor)
                }
            }
            .padding(DSMetrics.Popover.infoPadding)

        }
    }
}

/// Блок «Детекторы» (макеты поповеров): строка на детектор — иконка
/// состояния, имя, состояние с его основаниями; выключенные приглушены.
@MainActor
private struct DetectorsBlock: View {
    let detectors: [DetectorSnapshot]
    let observeOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Детекторы")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(DSColor.textTertiary)
            ForEach(detectors) { detector in
                // В одну строку, как в макете, пока имя и основания помещаются;
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
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            state(of: detector)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
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
    }

    private func state(of detector: DetectorSnapshot) -> some View {
        Text(DetectorPresentation.stateText(for: detector, observeOnly: observeOnly))
            .font(DSFont.caption)
            .foregroundStyle(DetectorPresentation.stateColor(for: detector))
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
    private var text: MenuStatusText { MenuStatusText(snapshot: snapshot, settings: settings) }
    var title: String { text.title }
    var subtitle: String { text.subtitle }
    var groupsValue: String { text.groupsValue }

    var banner: Banner? {
        guard let banner = text.banner else { return nil }
        let style: DSStatusBanner.Style = switch banner.style {
        case .ok: .ok
        case .warn: .warn
        case .danger: .danger
        }
        return Banner(style: style, title: banner.title, message: banner.message)
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
