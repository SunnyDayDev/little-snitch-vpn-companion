import SwiftUI

/// Подписи и цвета детектора — общие для списка во вкладке «Детекторы»,
/// экрана деталей и блока детекторов в поповере, чтобы они не расходились.
enum DetectorPresentation {
    /// «SOCKS5 203.0.113.5:1080 · реактивный · Telegram».
    static func subtitle(proxy: ProxyConfig, mode: ProtectionMode, groups: [String]) -> String {
        [proxyText(proxy), modeText(mode), groups.isEmpty ? "нет групп" : groups.joined(separator: ", ")]
            .joined(separator: " · ")
    }

    static func proxyText(_ proxy: ProxyConfig) -> String {
        switch proxy.kind {
        case .direct: "без прокси"
        case .httpConnect: "HTTP CONNECT \(proxy.address)"
        case .socks5: "SOCKS5 \(proxy.address)"
        }
    }

    static func modeText(_ mode: ProtectionMode) -> String {
        mode == .strict ? "строгий" : "реактивный"
    }

    /// Чип состояния: «Защищён», «Утечка», «Офлайн», «Проверка», «Выключен».
    /// Офлайн строгого детектора — warn: его трафик закрыт.
    static func chip(for detector: DetectorSnapshot) -> (text: String, style: DSStatusChip.Style) {
        guard detector.isEnabled else { return ("Выключен", .neutral) }
        return switch detector.state {
        case .protected: ("Защищён", .ok)
        case .leak: ("Утечка", .danger)
        case .offline: ("Офлайн", detector.mode == .strict ? .warn : .neutral)
        case .checking: ("Проверка", .warn)
        case .paused: ("Пауза", .warn)
        }
    }

    /// Состояние с egress для строки блока «Детекторы» в поповере.
    static func stateText(for detector: DetectorSnapshot) -> String {
        guard detector.isEnabled else { return "выключен" }
        switch detector.state {
        case .protected:
            guard let trace = detector.trace else { return "защищён" }
            var parts = ["защищён", trace.ip.text]
            if trace.warp.indicatesWarp { parts.append("warp=\(trace.warp.rawValue)") }
            return parts.joined(separator: " · ")
        case .leak:
            return detector.trace.map { "утечка · \($0.ip.text)" } ?? "утечка"
        case .checking:
            return "проверка · ждём вердикт"
        case .offline:
            return detector.mode == .strict ? "офлайн · закрыто" : "офлайн"
        case .paused:
            return "пауза"
        }
    }

    static func stateColor(for detector: DetectorSnapshot) -> Color {
        guard detector.isEnabled else { return DSColor.textTertiary }
        return switch detector.state {
        case .leak: DSColor.danger
        case .checking, .paused: DSColor.warn
        case .offline: detector.mode == .strict ? DSColor.warn : DSColor.textSecondary
        case .protected: DSColor.textSecondary
        }
    }

    /// «3 детектора · 2 включены».
    static func counter(total: Int, enabled: Int) -> String {
        "\(total) \(plural(total, one: "детектор", few: "детектора", many: "детекторов")) · "
            + "\(enabled) \(enabled % 10 == 1 && enabled % 100 != 11 ? "включён" : "включены")"
    }

    static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return many }
        switch count % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }
}
