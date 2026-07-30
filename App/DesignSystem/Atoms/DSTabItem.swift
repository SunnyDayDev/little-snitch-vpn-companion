import SwiftUI

/// Вкладка (§8.4): активная — иконка+ярлык accent на `bg-hover`; неактивная — secondary.
@MainActor
struct DSTabItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs / 2) {
                Image(systemName: icon)
                    .font(.system(size: DSIconSize.md))
                Text(label)
                    .font(DSFont.caption)
            }
            .foregroundStyle(isSelected ? DSColor.accent : DSColor.textSecondary)
            .padding(.vertical, DSSpacing.sm)
            .padding(.horizontal, DSSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md)
                    .fill(isSelected ? DSColor.bgHover : .clear)
            )
            // Без этого у неактивной вкладки прозрачный фон не ловит клик,
            // и попасть можно только по иконке или ярлыку.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DSTabItemPreviewContent: View {
    @State private var selected = 0

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            DSTabItem(icon: "gearshape", label: "Общие", isSelected: selected == 0) { selected = 0 }
            DSTabItem(icon: "waveform.path.ecg", label: "Детектор", isSelected: selected == 1) { selected = 1 }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Вкладка · светлая") {
    DSTabItemPreviewContent()
}

#Preview("Вкладка · тёмная") {
    DSTabItemPreviewContent()
        .preferredColorScheme(.dark)
}
