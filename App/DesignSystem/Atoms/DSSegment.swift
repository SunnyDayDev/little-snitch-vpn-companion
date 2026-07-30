import SwiftUI

/// Сегмент (§8.4): один пункт сегмент-контрола. Активный — `bg-card` с тенью,
/// неактивный — прозрачный фон, текст secondary.
@MainActor
struct DSSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                .padding(.vertical, DSSpacing.xs)
                .padding(.horizontal, DSSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .fill(isSelected ? DSColor.bgCard : .clear)
                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
                )
                // У невыбранного сегмента фон прозрачный и клик по нему
                // не проходил — ловим всю область.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DSSegmentPreviewContent: View {
    @State private var selected = 0

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            DSSegment(title: "Общие", isSelected: selected == 0) { selected = 0 }
            DSSegment(title: "Детектор", isSelected: selected == 1) { selected = 1 }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Сегмент · светлая") {
    DSSegmentPreviewContent()
}

#Preview("Сегмент · тёмная") {
    DSSegmentPreviewContent()
        .preferredColorScheme(.dark)
}
