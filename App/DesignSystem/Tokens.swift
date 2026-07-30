import AppKit
import SwiftUI

// Токены дизайн-системы (§8.1–8.3 SPEC.md). Атомы и молекулы используют только эти
// значения — никаких хардкод-цветов, радиусов и размеров в самих вью.

/// Цветовые токены (§8.1): динамические `Color` со своими light/dark значениями.
/// Не используем `.primary`/`.secondary`/`Color.accentColor` — они следуют системным
/// настройкам пользователя (например, акцентный цвет macOS), а таблица §8.1 требует
/// фиксированных значений независимо от предпочтений пользователя.
enum DSColor {
    static let bgWindow = dynamic("bg-window", light: "#ECECEE", dark: "#232326")
    static let bgPopover = dynamic("bg-popover", light: "#F9F9FB", dark: "#1E1E21")
    static let bgCard = dynamic("bg-card", light: "#FFFFFF", dark: "#2C2C2E")
    static let bgHover = dynamic("bg-hover", light: "#0000000A", dark: "#FFFFFF0F")
    static let textPrimary = dynamic("text-primary", light: "#1D1D1F", dark: "#F5F5F7")
    static let textSecondary = dynamic("text-secondary", light: "#6E6E73", dark: "#98989D")
    static let textTertiary = dynamic("text-tertiary", light: "#AEAEB2", dark: "#636366")
    static let separator = dynamic("separator", light: "#E2E2E7", dark: "#3A3A3D")
    static let accent = dynamic("accent", light: "#007AFF", dark: "#0A84FF")
    static let ok = dynamic("ok", light: "#34C759", dark: "#30D158")
    static let danger = dynamic("danger", light: "#FF3B30", dark: "#FF453A")
    static let warn = dynamic("warn", light: "#FF9500", dark: "#FF9F0A")
    static let muted = dynamic("muted", light: "#8E8E93", dark: "#8E8E93")
    static let okBg = dynamic("ok-bg", light: "#34C75914", dark: "#30D15820")
    static let dangerBg = dynamic("danger-bg", light: "#FF3B3012", dark: "#FF453A22")

    /// Светофор окна: нативные цвета кнопок закрытия/сворачивания/раскрытия macOS,
    /// одинаковые в обеих темах — не берём из таблицы §8.1 (там их нет).
    static let trafficClose = staticColor("#FF5F57")
    static let trafficMinimize = staticColor("#FEBC2E")
    static let trafficZoom = staticColor("#28C840")

    private static func dynamic(_ token: String, light: String, dark: String) -> Color {
        Color(nsColor: NSColor(
            name: NSColor.Name("DesignSystem/\(token)"),
            dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hexToken: isDark ? dark : light)
            }
        ))
    }

    private static func staticColor(_ hex: String) -> Color {
        Color(nsColor: NSColor(hexToken: hex))
    }
}

private extension NSColor {
    /// Разбирает `#RRGGBB` или `#RRGGBBAA` из таблицы §8.1 (альфа — последний байт).
    convenience init(hexToken hex: String) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        if digits.count == 8 {
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// Типографика (§8.2): в макетах Inter/JetBrains Mono — макетная замена;
/// в реализации системные SF Pro (`.system`) и SF Mono (`design: .monospaced`).
enum DSFont {
    /// 18/bold — крупный заголовок онбординга.
    static let largeTitle = Font.system(size: 18, weight: .bold)
    /// 15/semibold — заголовок поповера, шапка статуса.
    static let popoverTitle = Font.system(size: 15, weight: .semibold)
    /// 13/semibold — тайтлбары, названия групп, титулы строк.
    static let windowTitle = Font.system(size: 13, weight: .semibold)
    /// 13/regular — пункты меню, описания.
    static let body = Font.system(size: 13, weight: .regular)
    /// 12/medium — значения инфо-строк.
    static let valueLabel = Font.system(size: 12, weight: .medium)
    /// 12/regular — подзаголовки, баннерный текст.
    static let secondary = Font.system(size: 12, weight: .regular)
    /// 11/semibold — заголовки секций (выводить капсом через `.textCase(.uppercase)`).
    static let sectionCaption = Font.system(size: 11, weight: .semibold)
    /// 11/regular — сабтайтлы строк, футеры.
    static let caption = Font.system(size: 11, weight: .regular)
    /// 11/regular mono — IP, URL, egress.
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
}

/// Радиусы (§8.3).
enum DSRadius {
    /// 4 — чекбокс.
    static let xs: CGFloat = 4
    /// 6 — поля, сегменты, кнопки, пункты меню, чипы.
    static let sm: CGFloat = 6
    /// 8 — баннеры, вкладки, сегмент-контрол.
    static let md: CGFloat = 8
    /// 10 — карточки, таблицы.
    static let lg: CGFloat = 10
    /// 12 — окна.
    static let xl: CGFloat = 12
    /// 16 — поповер, значок онбординга.
    static let xxl: CGFloat = 16
}

/// Шкала отступов 4/8/14/20 (§8.3).
enum DSSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
}

/// Размеры иконок (§8.3): 13/15/18/26 pt.
enum DSIconSize {
    static let xs: CGFloat = 13
    static let sm: CGFloat = 15
    static let md: CGFloat = 18
    static let lg: CGFloat = 26
}

/// Метрики отдельных компонентов (§8.3), не выражаемые общей шкалой отступов/радиусов.
enum DSMetrics {
    static let toggleWidth: CGFloat = 36
    static let toggleHeight: CGFloat = 21
    static let toggleKnobDiameter: CGFloat = 17
    static let checkboxSize: CGFloat = 16
    static let checkboxStrokeWidth: CGFloat = 1.5
    static let trafficLightDiameter: CGFloat = 12
    static let stepBadgeDiameter: CGFloat = 24
    static let menuBarChipWidth: CGFloat = 34
    static let menuBarChipHeight: CGFloat = 24
    static let menuBarChipIconSize: CGFloat = 16
    static let separatorThickness: CGFloat = 1
    /// Точное значение §8.4 (кнопка первичная/вторичная): паддинг 6×14 — вертикаль вне
    /// общей шкалы отступов, поэтому вынесена отдельным токеном.
    static let buttonPaddingVertical: CGFloat = 6

    /// Поповер строки меню: у секций разные горизонтальные отступы
    /// (шапка и инфо 16, баннер 12, пункты меню 8) — снято с макета
    /// `design/app.pen`, листы «Поповер».
    enum Popover {
        static let width: CGFloat = 340
        static let headerPadding = EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16)
        static let bannerPadding = EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12)
        static let infoPadding = EdgeInsets(top: 2, leading: 16, bottom: 10, trailing: 16)
        static let infoRowGap: CGFloat = 7
        static let menuPadding = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        static let footerPadding = EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8)
        static let menuItemGap: CGFloat = 1
        static let headerGap: CGFloat = 10
    }

    /// Баннер состояния: внутренний паддинг 10 и шаг 3 между титулом и текстом.
    enum Banner {
        static let padding: CGFloat = 10
        static let gap: CGFloat = 3
    }

    /// Таблицы (§8.3: внутри строк 10–14). Значения — с макетов «Настройки —
    /// Группы» и «Журнал».
    enum Table {
        static let horizontalPadding: CGFloat = 14
        static let headerVerticalPadding: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 10
        static let journalRowVerticalPadding: CGFloat = 9
        static let columnGap: CGFloat = 10
    }

    /// Окно журнала: ширина и ширины колонок таблицы (макет «Журнал»).
    enum Journal {
        static let width: CGFloat = 760
        static let height: CGFloat = 460
        static let toolbarPadding = EdgeInsets(top: 2, leading: 14, bottom: 10, trailing: 14)
        static let contentPadding = EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14)
        static let contentGap: CGFloat = 10
        static let timeColumn: CGFloat = 76
        static let triggerColumn: CGFloat = 96
        static let egressColumn: CGFloat = 150
        static let eventColumn: CGFloat = 132
        static let actionColumn: CGFloat = 210
    }

    /// Окно настроек (макет «Настройки — Группы»).
    enum Settings {
        static let width: CGFloat = 720
        static let height: CGFloat = 560
        static let contentPadding: CGFloat = 20
        static let contentGap: CGFloat = 14
        static let tabBarGap: CGFloat = 10
        static let tabBarPadding = EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0)
        static let cardRowGap: CGFloat = 14
    }

    /// Метрики онбординга и карточки-шага, снятые с макета `design/app.pen`
    /// (лист «Онбординг»). Шкала §8.3 их не покрывает, но во вью хардкода быть
    /// не должно — поэтому они живут здесь как именованные токены.
    enum Onboarding {
        /// Отступ между значком, заголовками, шагами и точками прогресса.
        static let sectionGap: CGFloat = 18
        /// Паддинг контента окна: сверху 8 (под тайтлбаром), по бокам 28, снизу 24.
        static let contentTopPadding: CGFloat = 8
        static let contentSidePadding: CGFloat = 28
        static let contentBottomPadding: CGFloat = 24
        /// Высота тайтлбара окна — на неё сдвигается контент при скрытом заголовке.
        static let titleBarHeight: CGFloat = 32
        static let appIconSize: CGFloat = 64
        static let appIconGlyphSize: CGFloat = 34
        static let headerGap: CGFloat = 6
        /// Расстояние между карточками шагов.
        static let stepGap: CGFloat = 10
        /// Внутри карточки: бейдж ↔ тексты.
        static let stepCardGap: CGFloat = 12
        static let progressDotSize: CGFloat = 7
        static let progressDotGap: CGFloat = 6
    }
}
