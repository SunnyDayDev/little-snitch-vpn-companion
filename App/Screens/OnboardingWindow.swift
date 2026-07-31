import SwiftUI

/// Онбординг первого запуска (§7.6 SPEC.md), 560 pt. Состав и метрики — по
/// макету `design/app.pen`, лист «Онбординг»: значок и заголовки по центру,
/// три карточки-шага, точки прогресса внизу.
@MainActor
struct OnboardingWindow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var notificationsGranted = false

    private static let stepCount = 3

    var body: some View {
        VStack(spacing: DSMetrics.Onboarding.sectionGap) {
            appIcon

            VStack(spacing: DSMetrics.Onboarding.headerGap) {
                Text("Little Snitch VPN Companion")
                    .font(DSFont.largeTitle)
                    .foregroundStyle(DSColor.textPrimary)
                Text("""
                    Следит за фактическим egress и при утечке блокирует запрещённые \
                    приложения через Little Snitch. Три шага для начала работы.
                    """)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: DSMetrics.Onboarding.stepGap) {
                DSStepCard(
                    number: 1,
                    title: "Разрешить привилегированный helper",
                    description: """
                        Helper — единственный компонент с правами root: только он вызывает \
                        littlesnitch CLI. Подтверди установку в System Settings → Основные → \
                        Объекты входа.
                        """,
                    isActive: step == 0,
                    action: .button(title: helperButtonTitle) {
                        Task {
                            await model.installHelper()
                            if model.helperStatus.isReady
                                || model.helperStatus == .requiresApproval {
                                step = max(step, 1)
                            }
                        }
                    })

                DSStepCard(
                    number: 2,
                    title: "Создать rule group в Little Snitch",
                    // Текст режимо-нейтральный («когда трафик закрыт» покрывает и
                    // утечку, и строгий режим) с предупреждением о самозапирании.
                    description: """
                        Группа «VPN down» с deny-правилами для Claude, JetBrains и \
                        Android Studio. Companion включает её, когда трафик закрыт, \
                        и выключает при подтверждённом VPN. Не включайте в группу \
                        браузер и VPN-клиент — иначе при закрытом трафике будет \
                        нечем пройти captive portal и поднять VPN.
                        """,
                    isActive: step == 1,
                    action: .link(title: "Открыть Little Snitch…") {
                        model.openLittleSnitch()
                        step = max(step, 2)
                    })

                DSStepCard(
                    number: 3,
                    title: "Разрешить уведомления",
                    description: """
                        Сообщения о переходах: утечка обнаружена, защита восстановлена, \
                        отказ helper.
                        """,
                    isActive: step == 2,
                    action: .button(title: notificationsGranted ? "Разрешено" : "Разрешить…") {
                        Task {
                            notificationsGranted = await model.requestNotificationAuthorization()
                            step = max(step, 2)
                        }
                    })
            }

            progressDots
        }
        .padding(.top, DSMetrics.Onboarding.titleBarHeight
            + DSMetrics.Onboarding.contentTopPadding)
        .padding(.horizontal, DSMetrics.Onboarding.contentSidePadding)
        .padding(.bottom, DSMetrics.Onboarding.contentBottomPadding)
        .frame(width: 560)
        .background(DSColor.bgWindow)
        .task { await model.refreshHelperState() }
        // В макете завершающей кнопки нет: онбординг закрывается окном.
        // Закрытие считается прохождением — иначе он всплывал бы каждый запуск.
        .onDisappear { model.finishOnboarding() }
    }

    private var appIcon: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: DSMetrics.Onboarding.appIconGlyphSize))
            .foregroundStyle(.white)
            .frame(width: DSMetrics.Onboarding.appIconSize,
                   height: DSMetrics.Onboarding.appIconSize)
            .background(DSColor.accent, in: RoundedRectangle(cornerRadius: DSRadius.xxl))
    }

    private var progressDots: some View {
        HStack(spacing: DSMetrics.Onboarding.progressDotGap) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Circle()
                    .fill(index == min(step, Self.stepCount - 1)
                        ? DSColor.accent : DSColor.separator)
                    .frame(width: DSMetrics.Onboarding.progressDotSize,
                           height: DSMetrics.Onboarding.progressDotSize)
            }
        }
    }

    private var helperButtonTitle: String {
        switch model.helperStatus {
        case .enabled: "Helper подключён"
        case .requiresApproval: "Открыть Системные настройки…"
        case .notRegistered, .notFound: "Установить helper…"
        }
    }
}
