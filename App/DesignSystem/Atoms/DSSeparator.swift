import SwiftUI

/// Разделитель (§8.4): линия 1 pt цвета `separator`.
@MainActor
struct DSSeparator: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .horizontal

    var body: some View {
        switch axis {
        case .horizontal:
            Rectangle()
                .fill(DSColor.separator)
                .frame(height: DSMetrics.separatorThickness)
        case .vertical:
            Rectangle()
                .fill(DSColor.separator)
                .frame(width: DSMetrics.separatorThickness)
        }
    }
}

#Preview("Разделитель · светлая") {
    VStack(spacing: DSSpacing.md) {
        Text("Проверить сейчас")
        DSSeparator()
        Text("Настройки…")
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Разделитель · тёмная") {
    VStack(spacing: DSSpacing.md) {
        Text("Проверить сейчас")
        DSSeparator()
        Text("Настройки…")
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
