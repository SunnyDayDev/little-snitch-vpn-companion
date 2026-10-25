import SwiftUI

/// Чип статуса (§8.4): подложка `ok-bg`/`danger-bg`/`warn-bg` + текст 12/semibold
/// соответствующего цвета; нейтральный — `bg-hover` и вторичный текст
/// (детектор выключен или без вердикта).
@MainActor
struct DSStatusChip: View {
    enum Style {
        case ok
        case danger
        case warn
        case neutral

        var background: Color {
            switch self {
            case .ok: DSColor.okBg
            case .danger: DSColor.dangerBg
            case .warn: DSColor.warnBg
            case .neutral: DSColor.bgHover
            }
        }

        var foreground: Color {
            switch self {
            case .ok: DSColor.ok
            case .danger: DSColor.danger
            case .warn: DSColor.warn
            case .neutral: DSColor.textSecondary
            }
        }
    }

    let text: String
    var style: Style = .ok

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(style.foreground)
            .padding(.vertical, DSSpacing.xs)
            .padding(.horizontal, DSSpacing.sm)
            .background(style.background, in: RoundedRectangle(cornerRadius: DSRadius.sm))
    }
}

#Preview("Чип статуса · светлая") {
    HStack(spacing: DSSpacing.sm) {
        DSStatusChip(text: "warp=on", style: .ok)
        DSStatusChip(text: "утечка", style: .danger)
        DSStatusChip(text: "Проверка", style: .warn)
        DSStatusChip(text: "Выключен", style: .neutral)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Чип статуса · тёмная") {
    HStack(spacing: DSSpacing.sm) {
        DSStatusChip(text: "warp=on", style: .ok)
        DSStatusChip(text: "утечка", style: .danger)
        DSStatusChip(text: "Проверка", style: .warn)
        DSStatusChip(text: "Выключен", style: .neutral)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
