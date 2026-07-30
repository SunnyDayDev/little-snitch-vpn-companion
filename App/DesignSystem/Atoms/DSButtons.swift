import SwiftUI

/// Кнопка первичная (§8.4): accent-фон, белый текст 12/semibold, паддинг 6×14.
@MainActor
struct DSPrimaryButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
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
    }
}

/// Кнопка вторичная (§8.4): `bg-card` + обводка, текст 12.
@MainActor
struct DSSecondaryButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.textPrimary)
                .padding(.vertical, DSMetrics.buttonPaddingVertical)
                .padding(.horizontal, DSSpacing.md)
                .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.sm)
                        .strokeBorder(DSColor.separator, lineWidth: DSMetrics.separatorThickness)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Кнопка-ссылка (§8.4): текст 12 accent, без фона.
@MainActor
struct DSLinkButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(DSColor.accent)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Кнопки · светлая") {
    HStack(spacing: DSSpacing.md) {
        DSPrimaryButton("Установить helper…") {}
        DSSecondaryButton("Переустановить…") {}
        DSLinkButton("Открыть Little Snitch…") {}
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Кнопки · тёмная") {
    HStack(spacing: DSSpacing.md) {
        DSPrimaryButton("Установить helper…") {}
        DSSecondaryButton("Переустановить…") {}
        DSLinkButton("Открыть Little Snitch…") {}
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
