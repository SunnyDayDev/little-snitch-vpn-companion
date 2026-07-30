import SwiftUI

/// Чекбокс (§8.4): вкл — accent-заливка с белой галкой; выкл — `bg-card` с обводкой 1.5 pt.
@MainActor
struct DSCheckbox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: DSRadius.xs)
                .fill(isOn ? DSColor.accent : DSColor.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.xs)
                        .strokeBorder(
                            isOn ? .clear : DSColor.separator,
                            lineWidth: DSMetrics.checkboxStrokeWidth
                        )
                )
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: DSMetrics.checkboxSize, height: DSMetrics.checkboxSize)
                // Зона попадания шире самого чекбокса (16 pt слишком мелко),
                // при этом вёрстка не меняется: паддинг тут же снимается.
                .padding(6)
                .contentShape(Rectangle())
                .padding(-6)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}

private struct DSCheckboxPreviewContent: View {
    @State private var checked = true
    @State private var unchecked = false

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            DSCheckbox(isOn: $checked)
            DSCheckbox(isOn: $unchecked)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Чекбокс · светлая") {
    DSCheckboxPreviewContent()
}

#Preview("Чекбокс · тёмная") {
    DSCheckboxPreviewContent()
        .preferredColorScheme(.dark)
}
