import SwiftUI

/// Кнопка первичная (§8.4): accent-фон, белый текст 12/semibold, паддинг 6×14.
/// Неактивная — та же кнопка с прозрачностью 45 % (атом «Кнопка первичная
/// неактивная» в макете): пока идёт операция, нажимать нечего.
@MainActor
struct DSPrimaryButton: View {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, DSMetrics.buttonPaddingVertical)
                .padding(.horizontal, DSSpacing.md)
                .background(DSColor.accent, in: RoundedRectangle(cornerRadius: DSRadius.sm))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : DSMetrics.disabledPrimaryOpacity)
        .disabled(!isEnabled)
    }
}

/// Кнопка вторичная (§8.4): `bg-card` + обводка, текст 12. Неактивная —
/// третичный цвет текста (атом «Кнопка вторичная неактивная» в макете).
@MainActor
struct DSSecondaryButton: View {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isEnabled ? DSColor.textPrimary : DSColor.textTertiary)
                .padding(.vertical, DSMetrics.buttonPaddingVertical)
                .padding(.horizontal, DSSpacing.md)
                .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .strokeBorder(DSColor.separator, lineWidth: DSMetrics.separatorThickness)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Кнопка-ссылка (§8.4): текст 12 accent, без фона. Шрифт настраивается:
/// в подписи строки настройки ссылка стоит в одной строке с текстом 11.
@MainActor
struct DSLinkButton: View {
    private let title: String
    private let font: Font
    private let action: () -> Void

    init(_ title: String, font: Font = .system(size: 12), action: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(DSColor.accent)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Кнопки · светлая") {
    HStack(spacing: DSSpacing.md) {
        DSPrimaryButton("Установить helper…") {}
        DSPrimaryButton("Устанавливаем…", isEnabled: false) {}
        DSSecondaryButton("Переустановить…") {}
        DSSecondaryButton("Переустанавливаем…", isEnabled: false) {}
        DSLinkButton("Открыть Little Snitch…") {}
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
}

#Preview("Кнопки · тёмная") {
    HStack(spacing: DSSpacing.md) {
        DSPrimaryButton("Установить helper…") {}
        DSPrimaryButton("Устанавливаем…", isEnabled: false) {}
        DSSecondaryButton("Переустановить…") {}
        DSSecondaryButton("Переустанавливаем…", isEnabled: false) {}
        DSLinkButton("Открыть Little Snitch…") {}
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgPopover)
    .preferredColorScheme(.dark)
}
