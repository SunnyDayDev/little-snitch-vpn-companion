import SwiftUI

/// Шапка статуса (§8.5): статус-иконка 26 + заголовок 15/semibold + подзаголовок 12 secondary.
@MainActor
struct DSStatusHeader: View {
    let state: DSStatusIcon.State
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            DSStatusIcon(state: state)
            VStack(alignment: .leading, spacing: DSSpacing.xs / 2) {
                Text(title)
                    .font(DSFont.popoverTitle)
                    .foregroundStyle(DSColor.textPrimary)
                Text(subtitle)
                    .font(DSFont.secondary)
                    .foregroundStyle(DSColor.textSecondary)
                    // IPv6-egress маяка длиннее строки поповера — переносим,
                    // а не обрезаем: адрес нужен целиком.
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Шапка статуса · светлая") {
    VStack(alignment: .leading, spacing: DSSpacing.md) {
        DSStatusHeader(
            state: .protected,
            title: "Защищено",
            subtitle: "egress 104.28.200.5 · warp=on · AMS"
        )
        DSStatusHeader(
            state: .leak,
            title: "Утечка",
            subtitle: "egress 203.0.113.5 — трафик идёт напрямую"
        )
    }
    .frame(width: 320, alignment: .leading)
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
}

#Preview("Шапка статуса · тёмная") {
    VStack(alignment: .leading, spacing: DSSpacing.md) {
        DSStatusHeader(
            state: .protected,
            title: "Защищено",
            subtitle: "egress 104.28.200.5 · warp=on · AMS"
        )
        DSStatusHeader(
            state: .leak,
            title: "Утечка",
            subtitle: "egress 203.0.113.5 — трафик идёт напрямую"
        )
    }
    .frame(width: 320, alignment: .leading)
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
    .preferredColorScheme(.dark)
}
