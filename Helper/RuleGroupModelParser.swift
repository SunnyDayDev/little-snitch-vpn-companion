import Foundation

/// Выборочный разбор `littlesnitch export-model`. Формат не документирован и
/// может меняться с версиями LS (§9 SPEC.md), поэтому парсер ищет группы по
/// форме объекта, а не по фиксированному пути в дереве: объект с текстовым
/// именем и булевым признаком включённости.
///
/// Наружу отдаются только имена и статусы — модель может быть большой.
enum RuleGroupModelParser {
    struct ParseFailure: Error, CustomStringConvertible {
        let topLevelKeys: [String]
        /// Форма узлов-кандидатов: без неё непонятно, чем именно отличается
        /// формат LS от ожидаемого (структура export-model не документирована).
        let candidateShapes: [String]

        var description: String {
            var parts = ["в модели LS не найдено rule groups"]
            if !topLevelKeys.isEmpty {
                parts.append("ключи верхнего уровня: " + topLevelKeys.joined(separator: ", "))
            }
            if !candidateShapes.isEmpty {
                parts.append("форма: " + candidateShapes.joined(separator: " | "))
            }
            return parts.joined(separator: "; ")
        }
    }

    /// `userProvidedName` — так имя группы называется в модели LS
    /// (проверено на целевой машине 2026-07-30).
    private static let nameKeys = ["userProvidedName", "name", "Name", "groupName", "title"]
    private static let enabledKeys = ["enabled", "isEnabled", "active", "isActive", "on"]
    private static let disabledKeys = ["disabled", "isDisabled", "inactive"]
    /// Состояние группы может быть и строкой: `"state": "enabled"`.
    private static let stateKeys = ["state", "status", "activationState"]
    private static let enabledStates = ["enabled", "active", "on"]
    private static let disabledStates = ["disabled", "inactive", "off"]
    /// Ключи, под которыми в модели лежат сами группы.
    private static let groupContainerKeys = ["groups", "ruleGroups", "localRuleGroups",
                                             "subscribedRuleGroups"]

    /// Фактическая форма модели Little Snitch 6 (снято с целевой машины
    /// 2026-07-30): `groups` — словарь «внутренний id → описание группы», где
    ///
    /// - имя пользовательской группы лежит в `userProvidedName`;
    /// - встроенная группа имени не имеет вовсе, её опознаёт `type`
    ///   (`builtinMacOSServices`, `builtinICloudServices`);
    /// - `isActive` присутствует только у включённых групп: отсутствие ключа
    ///   означает «выключена», а не «неизвестно».
    private static func parseLittleSnitchGroups(_ root: Any) -> [String: Bool] {
        guard let dictionary = root as? [String: Any],
              let groups = dictionary["groups"] as? [String: Any] else { return [:] }

        var result: [String: Bool] = [:]
        for (id, value) in groups {
            guard let details = value as? [String: Any] else { continue }
            let name = (details["userProvidedName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (details["type"] as? String).flatMap(builtinGroupName)
            guard let name else {
                // Группа без имени и с неизвестным типом: показывать её как
                // внутренний идентификатор бессмысленно.
                continue
            }
            result[name] = (details["isActive"] as? Bool) ?? false
            _ = id
        }
        return result
    }

    /// Человекочитаемые имена встроенных групп — такими их показывает и
    /// принимает Little Snitch.
    private static func builtinGroupName(_ type: String) -> String? {
        switch type {
        case "builtinMacOSServices": "macOS Services"
        case "builtinICloudServices": "iCloud Services"
        default: nil
        }
    }

    static func parse(_ data: Data) throws -> [RuleGroupInfo] {
        let root = try JSONSerialization.jsonObject(with: data)

        // Сначала — известная форма LS 6; общий поиск остаётся запасным
        // вариантом на случай, если формат сменится с версией LS (§9 SPEC.md).
        let littleSnitchGroups = parseLittleSnitchGroups(root)
        if !littleSnitchGroups.isEmpty {
            return littleSnitchGroups
                .map { RuleGroupInfo(name: $0.key, enabled: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        var found: [String: Bool] = [:]
        var unnamed: Set<String> = []
        collect(from: root, into: &found, unnamedGroupShapes: &unnamed)

        guard !found.isEmpty else {
            let dictionary = root as? [String: Any]
            let keys = dictionary.map { Array($0.keys).sorted() } ?? []
            var shapes = ["groups", "ruleGroups", "profiles",
                          "noProfilePseudoProfile"].compactMap { key -> String? in
                guard let value = dictionary?[key] else { return nil }
                return "\(key): " + describeShape(value)
            }
            // Группы нашлись, но без человекочитаемого имени — показывать
            // внутренние идентификаторы LS пользователю нельзя.
            shapes.append(contentsOf: unnamed.sorted().prefix(4).map { "группа: " + $0 })
            throw ParseFailure(topLevelKeys: keys, candidateShapes: shapes)
        }
        return found
            .map { RuleGroupInfo(name: $0.key, enabled: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Ключ контейнера годится как имя группы, только если он выглядит именем,
    /// а не внутренним идентификатором LS (короткие строки вида «aaaaac»).
    private static func nameLikeKey(_ key: String) -> String? {
        let looksLikeIdentifier = key.count <= 8
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && key.rangeOfCharacter(from: .whitespaces) == nil
        return looksLikeIdentifier ? nil : key
    }

    /// Краткое описание формы узла: имена ключей и типы значений, два уровня.
    /// Нужно, чтобы по одной записи журнала понять фактический формат LS.
    private static func describeShape(_ node: Any, depth: Int = 0) -> String {
        switch node {
        case let array as [Any]:
            guard let first = array.first else { return "array[0]" }
            return "array[\(array.count)] → \(describeShape(first, depth: depth + 1))"
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted().prefix(12)
            let described = keys.map { key -> String in
                let value = dictionary[key]!
                let type = switch value {
                case is [Any]: "array"
                case is [String: Any]: "dict"
                case is Bool: "bool"
                case is String: "string"
                case is NSNumber: "number"
                default: "?"
                }
                return "\(key):\(type)"
            }
            let suffix = dictionary.count > 12 ? ", …\(dictionary.count - 12) ещё" : ""
            let inner = depth < 1
                ? dictionary.values.first.map { " → " + describeShape($0, depth: depth + 1) } ?? ""
                : ""
            return "dict{" + described.joined(separator: ", ") + suffix + "}" + inner
        case is Bool: return "bool"
        case is String: return "string"
        case is NSNumber: return "number"
        default: return "?"
        }
    }

    private static func collect(from node: Any, into found: inout [String: Bool],
                                unnamedGroupShapes: inout Set<String>) {
        switch node {
        case let dictionary as [String: Any]:
            if let group = ruleGroup(from: dictionary) {
                // Одноимённые вложенные объекты не должны затирать группу верхнего
                // уровня: побеждает первый найденный.
                if found[group.name] == nil { found[group.name] = group.enabled }
            }
            // Контейнер групп может быть словарём, где ключ — имя группы, а
            // значение описывает её без повторения имени внутри.
            for key in groupContainerKeys {
                guard let container = dictionary[key] as? [String: Any] else { continue }
                for (containerKey, value) in container {
                    guard let details = value as? [String: Any],
                          let enabled = enabledFlag(in: details) else { continue }
                    // Ключ контейнера годится как имя, только если он похож на
                    // имя: у LS это короткие внутренние идентификаторы вроде
                    // «aaaaac», показывать их пользователю нельзя.
                    guard let resolved = nameKeys.lazy.compactMap({ details[$0] as? String })
                        .first(where: { !$0.isEmpty }) ?? Self.nameLikeKey(containerKey)
                    else {
                        // Имени нет — в диагностику уходят строковые поля
                        // объекта: по ним видно, чем LS различает группы.
                        let strings = details
                            .compactMapValues { $0 as? String }
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: ", ")
                        unnamedGroupShapes.insert("\(containerKey){\(strings)}")
                        continue
                    }
                    if found[resolved] == nil { found[resolved] = enabled }
                }
            }
            for value in dictionary.values {
                collect(from: value, into: &found, unnamedGroupShapes: &unnamedGroupShapes)
            }

        case let array as [Any]:
            for value in array {
                collect(from: value, into: &found, unnamedGroupShapes: &unnamedGroupShapes)
            }

        default:
            break
        }
    }

    /// Признак включённости в любой из встречающихся форм: булев ключ,
    /// инвертированный булев ключ или строковое состояние.
    private static func enabledFlag(in dictionary: [String: Any]) -> Bool? {
        if let enabled = enabledKeys.lazy.compactMap({ dictionary[$0] as? Bool }).first {
            return enabled
        }
        if let disabled = disabledKeys.lazy.compactMap({ dictionary[$0] as? Bool }).first {
            return !disabled
        }
        if let state = stateKeys.lazy.compactMap({ dictionary[$0] as? String }).first {
            let normalized = state.lowercased()
            if enabledStates.contains(normalized) { return true }
            if disabledStates.contains(normalized) { return false }
        }
        return nil
    }

    private static func ruleGroup(from dictionary: [String: Any]) -> RuleGroupInfo? {
        guard let name = nameKeys.lazy.compactMap({ dictionary[$0] as? String }).first,
              !name.isEmpty,
              let enabled = enabledFlag(in: dictionary) else { return nil }
        return RuleGroupInfo(name: name, enabled: enabled)
    }
}

/// То, что helper отдаёт приложению по XPC: только имя и статус.
struct RuleGroupInfo: Codable, Hashable {
    let name: String
    let enabled: Bool
}
