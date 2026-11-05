import Foundation

enum StatusText {
    static func safe(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {
                return String(format: "\\u{%X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
    static func render(_ document: StatusDocument) -> String {
        let monitoring = switch document.monitoring {
        case .running: "работает"
        case .paused: "пауза"
        case .stopped: "выключен"
        }
        var lines = ["Мониторинг: \(monitoring) · наблюдение: \(document.observeOnly ? "да" : "нет")",
                     "Helper: \(document.helperUnavailable ? "недоступен" : "нет признака недоступности")"]
        if let overall = document.overall { lines.append("Сводка: \(state(overall.state))") }
        lines.append(document.groups.known
            ? "Группы LS: \(document.groups.active!.isEmpty ? "выключены" : "включены (правила блокировки активны): " + list(document.groups.active!))"
            : "Группы LS: состояние групп неизвестно")
        let detectors = document.detectors ?? document.detector.map { [$0] } ?? []
        if detectors.isEmpty { lines.append("Детекторов нет") }
        else {
            lines.append("ID | Имя | Статус | Режим | Проверка | Растяжка")
            for detector in detectors {
                let age: String
                if let check = detector.lastCheck.flatMap(StatusDocument.date), let now = StatusDocument.date(document.capturedAt) {
                    age = "\(Int(max(0, now.timeIntervalSince(check)))) с назад"
                } else { age = "ещё не проверялся" }
                lines.append([safe(detector.id), safe(detector.name), state(detector.state),
                              detector.mode == .strict ? "строгий" : "реактивный", age,
                              detector.tripwireActive ? "активна" : "неактивна"].joined(separator: " | "))
                if let explanation = detector.explanation { lines.append("  Основание: \(reason(explanation))") }
                lines.append("  Назначенные группы: \(list(detector.assignedGroups))")
            }
        }
        return lines.joined(separator: "\n")
    }
    private static func list(_ values: [String]) -> String { values.isEmpty ? "нет" : values.map(safe).joined(separator: ", ") }
    private static func state(_ value: StatusState) -> String {
        switch value {
        case .protected: "защищён"
        case .leak: "утечка"
        case .offline: "офлайн"
        case .checking: "проверка"
        case .paused: "пауза"
        case .disabled: "выключен"
        }
    }
    private static func reason(_ value: StatusExplanation) -> String {
        switch value {
        case .protected(let ip, let warp):
            return [ip.map(safe), warp.map { "warp=\($0.rawValue)" }].compactMap { $0 }.joined(separator: " · ")
        case .leak(let ip, let diagnosis):
            let reason = switch diagnosis {
            case .forbiddenServer: "выход с запрещённого сервера"
            case .directRuIP: "полный обход VPN"
            case .foreignEgress: "egress не соответствует правилам защиты"
            }
            return "\(safe(ip)) — \(reason)"
        case .offline(let cause):
            return switch cause {
            case .noNetwork: "нет сети"
            case .beaconUnavailable: "маяк недоступен"
            case .unknown: "нет результата проверки"
            }
        }
    }
}
