import SwiftUI

/// Таб-бар (§8.5): вкладки по центру (иконка 18 + ярлык 11) — контейнер атомов
/// `DSTabItem`; используется вкладками окна настроек (§7.2, «сверху в стиле System Settings»).
@MainActor
struct DSTabBar: View {
    struct Item {
        let icon: String
        let label: String

        init(icon: String, label: String) {
            self.icon = icon
            self.label = label
        }
    }

    let items: [Item]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                DSTabItem(icon: item.icon, label: item.label, isSelected: index == selection) {
                    selection = index
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct DSTabBarPreviewContent: View {
    @State private var selection = 0

    var body: some View {
        DSTabBar(
            items: [
                .init(icon: "gearshape", label: "Общие"),
                .init(icon: "waveform.path.ecg", label: "Детектор"),
                .init(icon: "shield", label: "Группы"),
            ],
            selection: $selection
        )
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Таб-бар · светлая") {
    DSTabBarPreviewContent()
}

#Preview("Таб-бар · тёмная") {
    DSTabBarPreviewContent()
        .preferredColorScheme(.dark)
}
