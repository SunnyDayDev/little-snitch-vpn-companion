import SwiftUI

/// Строка настройки (§8.5): титул 13 + опциональная подпись 11, справа — произвольный
/// контрол (тумблер/кнопка/поле/чип/моно) через слот-замыкание. Подпись скрывается,
/// если не задана, — компонент один для всех строк настроек.
@MainActor
struct DSSettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: DSSpacing.xs / 2) {
                Text(title)
                    .font(DSFont.windowTitle)
                    .foregroundStyle(DSColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
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
                DSSecondaryButton("Переустановить…") {}
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
