import SwiftUI

/// Ссылка в подписи строки настройки: стоит в одной строке с текстом
/// подписи (макет «ждёт одобрения в Системных настройках · Открыть…»).
struct DSSubtitleLink {
    let title: String
    let action: () -> Void
}

/// Строка настройки (§8.5): титул 13 + опциональная подпись 11, справа — произвольный
/// контрол (тумблер/кнопка/поле/чип/моно) через слот-замыкание. Подпись скрывается,
/// если не задана, — компонент один для всех строк настроек. Тон подписи и
/// ссылка после неё — для строк со статусом (helper).
@MainActor
struct DSSettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var subtitleTone: DSTextTone = .normal
    var subtitleLink: DSSubtitleLink?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: DSSpacing.xs / 2) {
                Text(title)
                    .font(DSFont.windowTitle)
                    .foregroundStyle(DSColor.textPrimary)
                if let subtitle {
                    HStack(spacing: DSSpacing.xs) {
                        Text(subtitle)
                            .font(DSFont.caption)
                            .foregroundStyle(subtitleTone.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if let subtitleLink {
                            DSLinkButton(subtitleLink.title, font: DSFont.caption,
                                         action: subtitleLink.action)
                        }
                    }
                }
            }
            Spacer(minLength: DSSpacing.sm)
            control()
        }
    }
}

private struct DSSettingRowPreviewContent: View {
    @State private var autostart = true

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            DSSettingRow(
                title: "Запускать при входе в систему",
                subtitle: nil
            ) {
                DSToggle(isOn: $autostart)
            }
            DSSettingRow(
                title: "Режим наблюдения",
                subtitle: "только уведомления — группы Little Snitch не трогать"
            ) {
                DSToggle(isOn: .constant(false))
            }
            DSSettingRow(
                title: "Привилегированный helper",
                subtitle: "v1.0 · подключён · root"
            ) {
                DSSecondaryButton("Удалить…") {}
            }
            DSSettingRow(
                title: "Привилегированный helper",
                subtitle: "ждёт одобрения в Системных настройках ·",
                subtitleTone: .warning,
                subtitleLink: DSSubtitleLink(title: "Открыть Системные настройки…") {}
            ) {
                DSSecondaryButton("Удалить…") {}
            }
            DSSettingRow(
                title: "Привилегированный helper",
                subtitle: "переустанавливаем: ждём launchd… 12 с"
            ) {
                DSSecondaryButton("Переустанавливаем…", isEnabled: false) {}
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgCard)
    }
}

#Preview("Строка настройки · светлая") {
    DSSettingRowPreviewContent()
}

#Preview("Строка настройки · тёмная") {
    DSSettingRowPreviewContent()
        .preferredColorScheme(.dark)
}
