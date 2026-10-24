import SwiftUI

/// Ряд детектора (макет «Молекула/Ряд детектора»): иконка состояния 18,
/// имя 13 medium, подпись 11 «прокси · режим · группы», чип состояния и
/// шеврон перехода в детали. Выключенный детектор — приглушённый щит.
@MainActor
struct DSDetectorRow: View {
    let state: DSStatusIcon.State
    var isEnabled = true
    let name: String
    let subtitle: String
    let chipText: String
    let chipStyle: DSStatusChip.Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isEnabled ? state.symbolName : DSSymbol.resolve("shield.slash"))
                    .font(.system(size: DSIconSize.md - 2))
                    .foregroundStyle(isEnabled ? state.color : DSColor.muted)
                    .frame(width: DSIconSize.md, height: DSIconSize.md)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DSColor.textPrimary)
                    Text(subtitle)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: DSSpacing.sm)
                DSStatusChip(text: chipText, style: chipStyle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DSColor.textTertiary)
            }
            .padding(.vertical, DSMetrics.Table.rowVerticalPadding)
            .padding(.horizontal, DSMetrics.Table.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DSDetectorRowPreviewContent: View {
    var body: some View {
        VStack(spacing: 0) {
            DSDetectorRow(state: .protected, name: "Основной",
                          subtitle: "без прокси · строгий · VPN down",
                          chipText: "Защищён", chipStyle: .ok) {}
            DSSeparator()
            DSDetectorRow(state: .leak, name: "Через резидентный прокси",
                          subtitle: "SOCKS5 203.0.113.5:1080 · реактивный · Telegram",
                          chipText: "Утечка", chipStyle: .danger) {}
            DSSeparator()
            DSDetectorRow(state: .offline, isEnabled: false, name: "Тестовый HTTP CONNECT",
                          subtitle: "HTTP CONNECT 127.0.0.1:8080 · реактивный · нет групп",
                          chipText: "Выключен", chipStyle: .neutral) {}
        }
        .frame(width: 660)
        .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.lg))
        .padding(DSSpacing.lg)
        .background(DSColor.bgWindow)
    }
}

#Preview("Ряд детектора · светлая") {
    DSDetectorRowPreviewContent()
}

#Preview("Ряд детектора · тёмная") {
    DSDetectorRowPreviewContent()
        .preferredColorScheme(.dark)
}
