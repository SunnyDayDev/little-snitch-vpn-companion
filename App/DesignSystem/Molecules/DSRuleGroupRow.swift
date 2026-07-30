import SwiftUI

/// Ряд группы LS (§8.5): имя 13 medium + опциональная подпись 11 (сведения из
/// export-model) + чекбокс «включать при утечке».
@MainActor
struct DSRuleGroupRow: View {
    let name: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DSSpacing.xs / 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DSColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            DSCheckbox(isOn: $isOn)
        }
    }
}

private struct DSRuleGroupRowPreviewContent: View {
    @State private var vpnDown = true
    @State private var other = false

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            DSRuleGroupRow(
                name: "VPN down",
                subtitle: "3 правила · deny",
                isOn: $vpnDown
            )
            DSRuleGroupRow(name: "Torrents", isOn: $other)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.bgCard)
    }
}

#Preview("Ряд группы LS · светлая") {
    DSRuleGroupRowPreviewContent()
}

#Preview("Ряд группы LS · тёмная") {
    DSRuleGroupRowPreviewContent()
        .preferredColorScheme(.dark)
}
