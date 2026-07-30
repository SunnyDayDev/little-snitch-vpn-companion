import AppKit
import SwiftUI

/// Статус-иконка (§8.4): щит 26 pt, символ и цвет зависят от состояния egress (§7.5).
@MainActor
struct DSStatusIcon: View {
    enum State {
        case protected
        case leak
        case offline
        case paused

        var symbolName: String {
            switch self {
            case .protected: DSSymbol.resolve("checkmark.shield")
            case .leak: DSSymbol.resolve("exclamationmark.shield")
            case .offline: DSSymbol.resolve("shield.slash")
            // §7.5 предлагает `minus.shield`, но такого символа в системе нет —
            // ТЗ разрешает ближайшую замену, берём щит из того же семейства.
            case .paused: DSSymbol.resolve("shield.lefthalf.filled")
            }
        }

        var color: Color {
            switch self {
            case .protected: DSColor.ok
            case .leak: DSColor.danger
            case .offline: DSColor.muted
            case .paused: DSColor.warn
            }
        }

        /// Доменное состояние → визуальное. Единственное место соответствия,
        /// чтобы поповер, окна и строка меню не расходились.
        init(_ state: EgressState) {
            self = switch state {
            case .protected: .protected
            case .leak: .leak
            case .offline: .offline
            case .paused: .paused
            }
        }
    }

    let state: State

    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: DSIconSize.lg))
            .foregroundStyle(state.color)
            .frame(width: DSIconSize.lg, height: DSIconSize.lg)
    }
}

/// Проверка существования SF Symbol. Несуществующее имя рисуется пустотой —
/// именно так пропала иконка паузы (`minus.shield` в системе нет), причём
/// молча: ни ошибки сборки, ни предупреждения в рантайме.
enum DSSymbol {
    private nonisolated(unsafe) static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func resolve(_ name: String, fallback: String = "shield") -> String {
        exists(name) ? name : fallback
    }

    static func exists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[name] { return known }
        let available = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        cache[name] = available
        return available
    }
}

#Preview("Статус-иконка · светлая") {
    HStack(spacing: DSSpacing.md) {
        DSStatusIcon(state: .protected)
        DSStatusIcon(state: .leak)
        DSStatusIcon(state: .offline)
        DSStatusIcon(state: .paused)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
}

#Preview("Статус-иконка · тёмная") {
    HStack(spacing: DSSpacing.md) {
        DSStatusIcon(state: .protected)
        DSStatusIcon(state: .leak)
        DSStatusIcon(state: .offline)
        DSStatusIcon(state: .paused)
    }
    .padding(DSSpacing.lg)
    .background(DSColor.bgWindow)
    .preferredColorScheme(.dark)
}
