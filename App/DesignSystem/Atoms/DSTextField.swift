import SwiftUI

/// Текстовое поле строки настройки (макет «Поле»): бокс `bg-window` r6,
/// обводка `separator`, текст 11. Значение применяется по Return или при
/// уходе фокуса, а не на каждый символ: промежуточная правка адреса прокси
/// иначе перезапускала бы растяжку детектора на каждом нажатии. Невалидное
/// значение подсвечивается `danger` и не применяется — в силе остаётся
/// прежнее. Неактивное поле не проверяется и не подсвечивается.
@MainActor
struct DSTextField: View {
    let value: String
    var placeholder = ""
    var isMonospaced = false
    var width: CGFloat = 260
    var isEnabled = true
    /// Проверка ввода; `nil` — принимается любое значение.
    var validate: ((String) -> Bool)?
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(isMonospaced ? DSFont.mono : DSFont.secondary)
            .foregroundStyle(isEnabled ? DSColor.textPrimary : DSColor.textTertiary)
            .focused($isFocused)
            .disabled(!isEnabled)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .frame(width: width)
            .background(DSColor.bgWindow, in: RoundedRectangle(cornerRadius: DSRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .strokeBorder(isValid ? DSColor.separator : DSColor.danger,
                                  lineWidth: DSMetrics.separatorThickness)
            )
            .onAppear { text = value }
            .onChange(of: value) { _, newValue in
                if !isFocused { text = newValue }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit(commit)
    }

    /// Неактивное поле не проверяется: его значение сейчас не применяется
    /// (адрес прокси у детектора без прокси), и красная рамка врала бы.
    private var isValid: Bool { !isEnabled || (validate?(text) ?? true) }

    private func commit() {
        guard isEnabled, isValid, text != value else { return }
        onCommit(text)
    }
}

#Preview("Текстовое поле · светлая") {
    VStack(spacing: DSSpacing.sm) {
        DSTextField(value: "203.0.113.5:1080", isMonospaced: true,
                    validate: { ProxyConfig.parseAddress($0) != nil }) { _ in }
        DSTextField(value: "203.0.113.5", isMonospaced: true,
                    validate: { ProxyConfig.parseAddress($0) != nil }) { _ in }
        DSTextField(value: "Через резидентный прокси") { _ in }
        // Адрес прокси у детектора без прокси: неактивно, без рамки ошибки
        DSTextField(value: "", placeholder: "203.0.113.5:1080", isMonospaced: true,
                    isEnabled: false,
                    validate: { ProxyConfig.parseAddress($0) != nil }) { _ in }
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgCard)
}

#Preview("Текстовое поле · тёмная") {
    VStack(spacing: DSSpacing.sm) {
        DSTextField(value: "203.0.113.5:1080", isMonospaced: true,
                    validate: { ProxyConfig.parseAddress($0) != nil }) { _ in }
        DSTextField(value: "Через резидентный прокси") { _ in }
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgCard)
    .preferredColorScheme(.dark)
}
