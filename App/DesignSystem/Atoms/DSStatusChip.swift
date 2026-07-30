import SwiftUI

/// Чип статуса (§8.4): подложка `ok-bg`/`danger-bg` + текст 12/semibold соответствующего цвета.
@MainActor
struct DSStatusChip: View {
    enum Style {
        case ok
        case danger

        var background: Color {
            switch self {
            case .ok: DSColor.okBg
            case .danger: DSColor.dangerBg
            }
        }

        var foreground: Color {
            switch self {
            case .ok: DSColor.ok
            case .danger: DSColor.danger
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
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Чип статуса · тёмная") {
    HStack(spacing: DSSpacing.sm) {
        DSStatusChip(text: "warp=on", style: .ok)
        DSStatusChip(text: "утечка", style: .danger)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
