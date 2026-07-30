import SwiftUI

/// Чип строки меню (§8.4): контейнер 34×24 с иконкой 16 pt на `bg-hover` — визуальный
/// макет иконки companion в системной строке меню (§7.5).
@MainActor
struct DSMenuBarChip: View {
    let systemImage: String
    var tint: Color = DSColor.textPrimary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: DSMetrics.menuBarChipIconSize))
            .foregroundStyle(tint)
            .frame(width: DSMetrics.menuBarChipWidth, height: DSMetrics.menuBarChipHeight)
            .background(DSColor.bgHover, in: RoundedRectangle(cornerRadius: DSRadius.sm))
    }
}

#Preview("Чип строки меню · светлая") {
    HStack(spacing: DSSpacing.sm) {
        DSMenuBarChip(systemImage: "checkmark.shield")
        DSMenuBarChip(systemImage: "exclamationmark.shield", tint: DSColor.danger)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Чип строки меню · тёмная") {
    HStack(spacing: DSSpacing.sm) {
        DSMenuBarChip(systemImage: "checkmark.shield")
        DSMenuBarChip(systemImage: "exclamationmark.shield", tint: DSColor.danger)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
