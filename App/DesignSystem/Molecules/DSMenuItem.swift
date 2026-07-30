import SwiftUI

/// Пункт меню (§8.5): иконка 15 + текст 13 + опциональный шорткат 12 tertiary.
/// Шорткат скрывается, если не задан, — один и тот же компонент подходит и для
/// «Проверить сейчас», и для «Завершить» с ⌘Q.
@MainActor
struct DSMenuItem: View {
    let icon: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: DSIconSize.sm))
                    .frame(width: DSIconSize.sm)
                Text(title)
                    .font(DSFont.body)
                Spacer(minLength: DSSpacing.sm)
                if let shortcut {
                    Text(shortcut)
                        .font(DSFont.secondary)
                        .foregroundStyle(DSColor.textTertiary)
                }
            }
            .foregroundStyle(DSColor.textPrimary)
            .padding(.vertical, DSSpacing.xs)
            .padding(.horizontal, DSSpacing.sm)
            .background(
                isHovering ? DSColor.bgHover : .clear,
                in: RoundedRectangle(cornerRadius: DSRadius.sm)
            )
            // Пункт меню — широкая строка со спейсером: без этого клик
            // проходил только по иконке и тексту, но не по пустому месту.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#Preview("Пункт меню · светлая") {
    VStack(spacing: 0) {
        DSMenuItem(icon: "arrow.clockwise", title: "Проверить сейчас") {}
        DSMenuItem(icon: "pause.circle", title: "Пауза мониторинга") {}
        DSMenuItem(icon: "power", title: "Завершить", shortcut: "⌘Q") {}
    }
    .frame(width: 260)
    .padding(DSSpacing.sm)
    .background(DSColor.bgPopover)
}

#Preview("Пункт меню · тёмная") {
    VStack(spacing: 0) {
        DSMenuItem(icon: "arrow.clockwise", title: "Проверить сейчас") {}
        DSMenuItem(icon: "pause.circle", title: "Пауза мониторинга") {}
        DSMenuItem(icon: "power", title: "Завершить", shortcut: "⌘Q") {}
    }
    .frame(width: 260)
    .padding(DSSpacing.sm)
    .background(DSColor.bgPopover)
    .preferredColorScheme(.dark)
}
