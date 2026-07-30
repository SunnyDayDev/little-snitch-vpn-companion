import SwiftUI

/// Баннер состояния (§8.5): подложка `ok-bg`/`danger-bg` + титул 12/semibold цветной
/// + текст 12 secondary.
@MainActor
struct DSStatusBanner: View {
    enum Style {
        case ok
        case danger

        var background: Color {
            switch self {
            case .ok: DSColor.okBg
            case .danger: DSColor.dangerBg
            }
        }

        var titleColor: Color {
            switch self {
            case .ok: DSColor.ok
            case .danger: DSColor.danger
            }
        }
    }

    let style: Style
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSMetrics.Banner.gap) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.titleColor)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Text(message)
                .font(DSFont.secondary)
                .foregroundStyle(DSColor.textSecondary)
                // Баннерный текст длинный по природе (перечисление групп,
                // объяснение диагноза) — он обязан переноситься, а не обрезаться.
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSMetrics.Banner.padding)
        .background(style.background, in: RoundedRectangle(cornerRadius: DSRadius.md))
    }
}

#Preview("Баннер состояния · светлая") {
    VStack(spacing: DSSpacing.md) {
        DSStatusBanner(
            style: .ok,
            title: "Цепочка работает",
            message: "Foreign-трафик уходит через VPN. Группы Little Snitch выключены."
        )
        DSStatusBanner(
            style: .danger,
            title: "Заблокированы: Claude, JetBrains, Android Studio",
            message: "Группа «VPN down» включена. Снимется автоматически, когда egress вернётся в цепочку."
        )
    }
    .frame(width: 320)
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
}

#Preview("Баннер состояния · тёмная") {
    VStack(spacing: DSSpacing.md) {
        DSStatusBanner(
            style: .ok,
            title: "Цепочка работает",
            message: "Foreign-трафик уходит через VPN. Группы Little Snitch выключены."
        )
        DSStatusBanner(
            style: .danger,
            title: "Заблокированы: Claude, JetBrains, Android Studio",
            message: "Группа «VPN down» включена. Снимется автоматически, когда egress вернётся в цепочку."
        )
    }
    .frame(width: 320)
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
    .preferredColorScheme(.dark)
}
