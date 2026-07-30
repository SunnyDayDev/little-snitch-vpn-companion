import SwiftUI

/// Тайтлбар окна (§8.5): светофор слева, титул 13/semibold по центру, справа —
/// спейсер, балансирующий ширину светофора, чтобы титул был визуально по центру.
@MainActor
struct DSWindowTitleBar: View {
    let title: String

    private var trafficLightWidth: CGFloat {
        DSMetrics.trafficLightDiameter * 3 + DSSpacing.sm * 2
    }

    var body: some View {
        HStack {
            DSTrafficLight()
            Spacer()
            Text(title)
                .font(DSFont.windowTitle)
                .foregroundStyle(DSColor.textPrimary)
            Spacer()
            Color.clear.frame(width: trafficLightWidth)
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
    }
}

#Preview("Тайтлбар окна · светлая") {
    DSWindowTitleBar(title: "Настройки")
        .background(DSColor.bgWindow)
}

#Preview("Тайтлбар окна · тёмная") {
    DSWindowTitleBar(title: "Настройки")
        .background(DSColor.bgWindow)
        .preferredColorScheme(.dark)
}
