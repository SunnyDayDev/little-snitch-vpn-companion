import SwiftUI

/// Поле со степпером (§8.4): бокс `bg-window` + обводка + шевроны вверх/вниз.
/// Используется для интервалов детектора (heartbeat, плановая проба, таймаут) в секундах.
@MainActor
struct DSStepperField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...999
    var step: Int = 1
    var unit: String?

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Text(unit.map { "\(value) \($0)" } ?? "\(value)")
                .font(DSFont.body)
                .foregroundStyle(DSColor.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
            VStack(spacing: 0) {
                chevron("chevron.up") { adjust(by: step) }
                chevron("chevron.down") { adjust(by: -step) }
            }
        }
        .padding(.vertical, DSSpacing.xs)
        .padding(.horizontal, DSSpacing.sm)
        .background(DSColor.bgWindow, in: RoundedRectangle(cornerRadius: DSRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.sm)
                .strokeBorder(DSColor.separator, lineWidth: DSMetrics.separatorThickness)
        )
    }

    private func chevron(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DSColor.textSecondary)
                // Шеврон 8 pt — слишком мелкая цель, ловим область вокруг.
                .padding(5)
                .contentShape(Rectangle())
                .padding(-5)
        }
        .buttonStyle(.plain)
    }

    private func adjust(by delta: Int) {
        value = min(range.upperBound, max(range.lowerBound, value + delta))
    }
}

private struct DSStepperFieldPreviewContent: View {
    @State private var heartbeat = 15
    @State private var timeout = 6

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            DSStepperField(value: $heartbeat, unit: "с")
            DSStepperField(value: $timeout, unit: "с")
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Поле со степпером · светлая") {
    DSStepperFieldPreviewContent()
}

#Preview("Поле со степпером · тёмная") {
    DSStepperFieldPreviewContent()
        .preferredColorScheme(.dark)
}
