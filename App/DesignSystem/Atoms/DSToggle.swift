import SwiftUI

/// Тумблер (§8.4): вкл — accent-фон и кноб справа; выкл — `bg-hover` с обводкой и кноб слева.
@MainActor
struct DSToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? DSColor.accent : DSColor.bgHover)
                    .overlay(
                        Capsule().strokeBorder(
                            DSColor.separator,
                            lineWidth: isOn ? 0 : DSMetrics.separatorThickness
                        )
                    )
                Circle()
                    .fill(.white)
                    .frame(width: DSMetrics.toggleKnobDiameter, height: DSMetrics.toggleKnobDiameter)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    // Инсет кноба выводится из размеров тумблера и кноба, а не задаётся числом.
                    .padding((DSMetrics.toggleHeight - DSMetrics.toggleKnobDiameter) / 2)
            }
        }
        .buttonStyle(.plain)
        .frame(width: DSMetrics.toggleWidth, height: DSMetrics.toggleHeight)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}

private struct DSTogglePreviewContent: View {
    @State private var enabled = true
    @State private var disabled = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            DSToggle(isOn: $enabled)
            DSToggle(isOn: $disabled)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Тумблер · светлая") {
    DSTogglePreviewContent()
}

#Preview("Тумблер · тёмная") {
    DSTogglePreviewContent()
        .preferredColorScheme(.dark)
}
