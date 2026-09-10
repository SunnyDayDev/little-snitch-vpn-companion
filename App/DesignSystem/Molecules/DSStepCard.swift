import SwiftUI

/// Карточка-шаг (§8.5): номер-бейдж 24 + титул 13/semibold + описание 12 +
/// опциональная строка статуса + опциональная кнопка/ссылка. Кнопка
/// скрывается, если действие не задано, — так же рендерится и завершающий
/// шаг онбординга. Закрытый шаг (`isDone`) получает отметку вместо номера
/// (макет «Онбординг — шаг 1: состояния»).
@MainActor
struct DSStepCard: View {
    enum Action {
        case button(title: String, isEnabled: Bool = true, handler: () -> Void)
        case secondaryButton(title: String, handler: () -> Void)
        case link(title: String, handler: () -> Void)
    }

    /// Строка статуса под описанием: текст с тоном и, при необходимости,
    /// ссылка в той же строке.
    struct Status {
        let text: String
        var tone: DSTextTone = .normal
        var link: DSSubtitleLink?
    }

    let number: Int
    let title: String
    let description: String
    var isActive: Bool = true
    var isDone: Bool = false
    var status: Status?
    var action: Action?

    var body: some View {
        HStack(alignment: .top, spacing: DSMetrics.Onboarding.stepCardGap) {
            badge
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
                if let status {
                    HStack(spacing: DSSpacing.xs) {
                        Text(status.text)
                            .font(DSFont.secondary)
                            .foregroundStyle(status.tone.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if let link = status.link {
                            DSLinkButton(link.title, action: link.action)
                        }
                    }
                }
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

    /// Бейдж активного шага — акцентный с белой цифрой, приглушённого —
    /// на подложке bg-hover с вторичной цифрой, закрытого — отметка на
    /// ok-фоне (макет «Онбординг»).
    @ViewBuilder
    private var badge: some View {
        Group {
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : DSColor.textSecondary)
            }
        }
        .frame(width: DSMetrics.stepBadgeDiameter, height: DSMetrics.stepBadgeDiameter)
        .background(badgeColor, in: Circle())
    }

    private var badgeColor: Color {
        if isDone { return DSColor.ok }
        return isActive ? DSColor.accent : DSColor.bgHover
    }

    @ViewBuilder
    private func actionView(_ action: Action) -> some View {
        switch action {
        case let .button(title, isEnabled, handler):
            DSPrimaryButton(title, isEnabled: isEnabled, action: handler)
        case let .secondaryButton(title, handler):
            DSSecondaryButton(title, action: handler)
        case let .link(title, handler):
            DSLinkButton(title, action: handler)
        }
    }
}

private let helperStepDescription = """
    Helper — единственный компонент с правами root: только он вызывает littlesnitch CLI. \
    Подтверди установку в System Settings → Основные → Объекты входа.
    """

#Preview("Карточка-шаг · светлая") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: helperStepDescription,
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

#Preview("Карточка-шаг · состояния helper") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: helperStepDescription,
            status: DSStepCard.Status(text: "регистрируем демон: ждём launchd… 12 с"),
            action: .button(title: "Устанавливаем…", isEnabled: false) {}
        )
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: helperStepDescription,
            status: DSStepCard.Status(
                text: "ждёт одобрения в Системных настройках ·",
                tone: .warning,
                link: DSSubtitleLink(title: "Открыть Системные настройки…") {}),
            action: .secondaryButton(title: "Удалить…") {}
        )
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: helperStepDescription,
            isDone: true,
            status: DSStepCard.Status(text: "v1.0 · подключён · root", tone: .ok)
        )
    }
    .frame(width: 504, alignment: .leading)
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Карточка-шаг · тёмная") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        DSStepCard(
            number: 1,
            title: "Разрешить привилегированный helper",
            description: helperStepDescription,
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
