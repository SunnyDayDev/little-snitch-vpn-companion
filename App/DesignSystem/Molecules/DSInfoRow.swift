import SwiftUI

/// Инфо-строка (§8.5): метка 12 secondary слева, значение 12 medium справа.
/// Цвет значения настраивается — например, красный для «Группы LS» при утечке.
@MainActor
struct DSInfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = DSColor.textPrimary

    var body: some View {
        HStack {
            Text(label)
                .font(DSFont.secondary)
                .foregroundStyle(DSColor.textSecondary)
            Spacer()
            Text(value)
                .font(DSFont.valueLabel)
                .foregroundStyle(valueColor)
        }
    }
}

#Preview("Инфо-строка · светлая") {
    VStack(spacing: DSSpacing.sm) {
        DSInfoRow(label: "Проверка", value: "12 с назад · TLS")
        DSInfoRow(label: "Группы LS", value: "выключены")
        DSInfoRow(label: "Группы LS", value: "включена «VPN down»", valueColor: DSColor.danger)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
}

#Preview("Инфо-строка · тёмная") {
    VStack(spacing: DSSpacing.sm) {
        DSInfoRow(label: "Проверка", value: "12 с назад · TLS")
        DSInfoRow(label: "Группы LS", value: "выключены")
        DSInfoRow(label: "Группы LS", value: "включена «VPN down»", valueColor: DSColor.danger)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
    .preferredColorScheme(.dark)
}
