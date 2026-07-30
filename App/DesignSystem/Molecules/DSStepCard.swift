import SwiftUI

/// Карточка-шаг (§8.5): номер-бейдж 24 + титул 13/semibold + описание 12 +
/// опциональная кнопка/ссылка. Кнопка скрывается, если действие не задано, —
/// так же рендерится и завершающий шаг онбординга.
@MainActor
struct DSStepCard: View {
    enum Action {
        case button(title: String, handler: () -> Void)
        case link(title: String, handler: () -> Void)
    }

    let number: Int
    let title: String
    let description: String
    var isActive: Bool = true
    var action: Action?

    var body: some View {
        HStack(alignment: .top, spacing: DSMetrics.Onboarding.stepCardGap) {
            // Бейдж активного шага — акцентный с белой цифрой, приглушённого —
            // на подложке bg-hover с вторичной цифрой (макет «Онбординг»).
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : DSColor.textSecondary)
                .frame(width: DSMetrics.stepBadgeDiameter, height: DSMetrics.stepBadgeDiameter)
                .background(isActive ? DSColor.accent : DSColor.bgHover, in: Circle())
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text(description)
                    .font(DSFont.secondary)
                    .foregroundStyle(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let action {
                    actionView(action)
                        .padding(.top, DSSpacing.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.bgCard, in: RoundedRectangle(cornerRadius: DSRadius.lg))
        .opacity(isActive ? 1 : 0.55)
    }

    @ViewBuilder
    private func actionView(_ action: Action) -> some View {
        switch action {
        case let .button(title, handler):
            DSPrimaryButton(title, action: handler)
        case let .link(title, handler):
            DSLinkButton(title, action: handler)
        }
    }
}

#Preview("Карточка-шаг · светлая") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: "Helper — единственный компонент с правами root: только он вызывает littlesnitch CLI.",
            isActive: true,
            action: .button(title: "Установить helper…") {}
        )
        DSStepCard(
            number: 2,
            title: "Создать rule group в Little Snitch",
            description: "Группа «VPN down» с deny-правилами для Claude, JetBrains и Android Studio.",
            isActive: false,
            action: .link(title: "Открыть Little Snitch…") {}
        )
        DSStepCard(
            number: 3,
            title: "Разрешить уведомления",
            description: "Сообщения о переходах: утечка обнаружена, защита восстановлена, отказ helper.",
            isActive: false
        )
    }
    .frame(width: 400, alignment: .leading)
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Карточка-шаг · тёмная") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: "Helper — единственный компонент с правами root: только он вызывает littlesnitch CLI.",
            isActive: true,
            action: .button(title: "Установить helper…") {}
        )
        DSStepCard(
            number: 2,
            title: "Создать rule group в Little Snitch",
            description: "Группа «VPN down» с deny-правилами для Claude, JetBrains и Android Studio.",
            isActive: false,
            action: .link(title: "Открыть Little Snitch…") {}
        )
    }
    .frame(width: 400, alignment: .leading)
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
