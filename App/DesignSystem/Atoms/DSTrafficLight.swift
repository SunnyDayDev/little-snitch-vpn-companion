import SwiftUI

/// Светофор окна (§8.4): три декоративных индикатора close/minimize/zoom.
/// Цвета фиксированы (native macOS), не зависят от темы.
@MainActor
struct DSTrafficLight: View {
    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            dot(DSColor.trafficClose)
            dot(DSColor.trafficMinimize)
            dot(DSColor.trafficZoom)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: DSMetrics.trafficLightDiameter, height: DSMetrics.trafficLightDiameter)
    }
}

#Preview("Светофор · светлая") {
    DSTrafficLight()
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
}

#Preview("Светофор · тёмная") {
    DSTrafficLight()
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
        .preferredColorScheme(.dark)
}
