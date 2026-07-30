import SwiftUI

/// Сегмент-контрол (§8.5): подложка `bg-hover` r8 с сегментами — контейнер инстансов
/// атома `DSSegment`.
@MainActor
struct DSSegmentedControl: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: DSSpacing.xs / 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                DSSegment(title: title, isSelected: index == selection) {
                    selection = index
                }
            }
        }
        .padding(DSSpacing.xs / 2)
        .background(DSColor.bgHover, in: RoundedRectangle(cornerRadius: DSRadius.md))
    }
}

private struct DSSegmentedControlPreviewContent: View {
    @State private var selection = 0

    var body: some View {
        DSSegmentedControl(titles: ["Все", "Переходы", "Действия", "Ошибки"], selection: $selection)
            .padding(DSSpacing.lg)
            .background(DSColor.bgWindow)
    }
}

#Preview("Сегмент-контрол · светлая") {
    DSSegmentedControlPreviewContent()
}

#Preview("Сегмент-контрол · тёмная") {
    DSSegmentedControlPreviewContent()
        .preferredColorScheme(.dark)
}
