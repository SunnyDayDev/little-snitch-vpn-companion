import Foundation

/// Выборочный разбор `littlesnitch export-model`. Формат не документирован и
/// может меняться с версиями LS (§9 SPEC.md), поэтому парсер ищет группы по
/// форме объекта, а не по фиксированному пути в дереве: объект с текстовым
/// именем и булевым признаком включённости.
///
/// Наружу отдаются только имена, статусы и вид групп — модель может быть большой.
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

    /// Поля, в которых Little Snitch хранит имя группы, в порядке приоритета
    /// (проверено на целевой машине 2026-09-09, LS 6.5):
    ///
    /// - `userProvidedName` — локальная группа;
    /// - `customName` — подписка, переименованная пользователем. Допущение:
    ///   в дампе ключ не встретился (подписка не была переименована), но
    ///   свойство есть у класса группы в бинаре CLI;
    /// - `factoryName` — подписка под именем из файла `.lsrules`.
    private static let littleSnitchNameKeys = ["userProvidedName", "customName", "factoryName"]
    /// Те же поля плюс общие имена — для запасного поиска по форме.
    private static let nameKeys = littleSnitchNameKeys + ["name", "Name", "groupName", "title"]
    private static let enabledKeys = ["enabled", "isEnabled", "active", "isActive", "on"]
    private static let disabledKeys = ["disabled", "isDisabled", "inactive"]
    /// Состояние группы может быть и строкой: `"state": "enabled"`.
    private static let stateKeys = ["state", "status", "activationState"]
    private static let enabledStates = ["enabled", "active", "on"]
    private static let disabledStates = ["disabled", "inactive", "off"]
    /// Ключи, под которыми в модели лежат сами группы.
    private static let groupContainerKeys = ["groups", "ruleGroups", "localRuleGroups",
                                             "subscribedRuleGroups"]

    /// Фактическая форма модели Little Snitch 6 (снимки с целевой машины
    /// 2026-07-30 и 2026-09-09, LS 6.5): `groups` — словарь «внутренний id →
    /// описание группы», где
    ///
    /// - локальная группа: имя в `userProvidedName`. Её `type` нестабилен
    ///   (в июле ключа не было, в сентябре — `loadedFromFile`), поэтому на
    ///   него не опираемся;
    /// - подписка по URL: `type: loadedFromURL`, имя из файла в `factoryName`,
    ///   адрес в `loadFromURL`;
    /// - встроенная группа имени не имеет вовсе, её опознаёт `type`
    ///   (`builtinMacOSServices`, `builtinICloudServices`);
    /// - `isActive` присутствует только у включённых групп любого вида:
    ///   отсутствие ключа означает «выключена», а не «неизвестно».
    ///
    /// Пропускается только запись без имени в любом виде: незнакомый `type`
    /// сам по себе не повод прятать группу, у которой имя есть, — именно так
    /// подписки и терялись. Одноимённые записи не схлопываются: разводит их
    /// приложение, у которого есть журнал для предупреждения.
    private static func parseLittleSnitchGroups(_ root: Any) -> [RuleGroupInfo] {
        guard let dictionary = root as? [String: Any],
              let groups = dictionary["groups"] as? [String: Any] else { return [] }

        var result: [RuleGroupInfo] = []
        for value in groups.values {
            guard let details = value as? [String: Any] else { continue }
            let type = details["type"] as? String
            let name = littleSnitchNameKeys.lazy
                .compactMap { details[$0] as? String }
                .first { !$0.isEmpty }
                ?? type.flatMap(builtinGroupName)
            guard let name else {
                // Ни имени, ни известного встроенного типа: показывать такую
                // запись как внутренний идентификатор бессмысленно.
                continue
            }
            result.append(RuleGroupInfo(name: name,
                                        enabled: (details["isActive"] as? Bool) ?? false,
                                        kind: kind(ofType: type)))
        }
        return sorted(result)
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

    /// Вид — по `type`, но только для двух устойчивых значений; всё прочее с
    /// именем считается локальной группой.
    private static func kind(ofType type: String?) -> HelperRuleGroupKind {
        switch type {
        case let type? where type.hasPrefix("builtin"): .builtin
        case "loadedFromURL": .remote
        default: .local
        }
    }

    /// Порядок детерминирован: по имени, при равных именах — по виду
    /// (локальная, встроенная, подписка). Приложение, оставляя первую из
    /// одноимённых, всегда оставляет одну и ту же.
    private static func sorted(_ groups: [RuleGroupInfo]) -> [RuleGroupInfo] {
        groups.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: kindOrder(lhs.kind) < kindOrder(rhs.kind)
            }
        }
    }

    private static func kindOrder(_ kind: HelperRuleGroupKind?) -> Int {
        switch kind {
        case .local: 0
        case .builtin: 1
        case .remote: 2
        case nil: 3
        }
    }

    static func parse(_ data: Data) throws -> [RuleGroupInfo] {
        let root = try JSONSerialization.jsonObject(with: data)

        // Сначала — известная форма LS 6; общий поиск остаётся запасным
        // вариантом на случай, если формат сменится с версией LS (§9 SPEC.md).
        let littleSnitchGroups = parseLittleSnitchGroups(root)
        if !littleSnitchGroups.isEmpty {
            return littleSnitchGroups
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
        // Запасной поиск о видах групп ничего не знает — `kind` остаётся пустым.
        return sorted(found.map { RuleGroupInfo(name: $0.key, enabled: $0.value) })
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

/// То, что helper отдаёт приложению по XPC: имя, статус и вид группы.
/// `kind` пуст, когда группу нашёл запасной поиск по форме: он о видах ничего
/// не знает, а выдумывать «локальная» нельзя. При кодировании `nil` опускается —
/// поле в JSON необязательное (см. `HelperProtocol.listRuleGroups`).
struct RuleGroupInfo: Codable, Hashable {
    let name: String
    let enabled: Bool
    let kind: HelperRuleGroupKind?

    init(name: String, enabled: Bool, kind: HelperRuleGroupKind? = nil) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
    }
}
