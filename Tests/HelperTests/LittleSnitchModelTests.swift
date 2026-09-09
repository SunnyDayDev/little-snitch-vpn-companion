import Foundation
import Testing

/// Фактическая модель Little Snitch 6, снятая с целевой машины (2026-07-30 и
/// 2026-09-09, LS 6.5). Форма подтверждена диагностикой: `groups` — словарь
/// «внутренний id → описание»; встроенные группы описаны `type`, локальные —
/// `userProvidedName`, подписки — `type: loadedFromURL` с именем из файла в
/// `factoryName`; `isActive` есть только у включённых групп любого вида.
@Suite("Модель Little Snitch 6")
struct LittleSnitchModelTests {
    private let model = Data("""
    {
      "bundleVersion": "6.5",
      "profiles": {},
      "noProfilePseudoProfile": {"name": ""},
      "groups": {
        "aaaaac": {"type": "builtinMacOSServices", "isActive": true,
                   "lastUpdateInvalidDomainsCount": 0, "updateInterval": 86400},
        "aaaaad": {"type": "builtinICloudServices", "isActive": true,
                   "lastUpdateInvalidDomainsCount": 0, "updateInterval": 86400},
        "ghoGzc": {"type": "loadedFromFile",
                   "userProvidedName": "Require VPN Services Local",
                   "creationDate": "2026-07-29T13:19:56Z",
                   "lastUpdateInvalidDomainsCount": 0, "updateInterval": 86400},
        "pykpmH": {"type": "loadedFromURL",
                   "factoryName": "Require VPN Services", "factoryDescription": "",
                   "loadFromURL": "https://example.com/require-vpn.lsrules",
                   "lastSuccessfulUpdate": "2026-09-09T03:07:40Z",
                   "lastUpdateInvalidDomainsCount": 0, "updateInterval": 86400}
      },
      "rules": []
    }
    """.utf8)

    private func byName(_ groups: [RuleGroupInfo]) -> [String: RuleGroupInfo] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
    }

    @Test("Имена: локальная из userProvidedName, подписка из factoryName, встроенные — по type")
    func parsesNames() throws {
        let groups = try RuleGroupModelParser.parse(model)
        #expect(groups.map(\.name) == ["iCloud Services", "macOS Services",
                                       "Require VPN Services",
                                       "Require VPN Services Local"])
    }

    @Test("Отсутствие isActive означает «выключена» у группы любого вида")
    func missingIsActiveMeansDisabled() throws {
        let groups = byName(try RuleGroupModelParser.parse(model))
        #expect(groups["macOS Services"]?.enabled == true)
        #expect(groups["iCloud Services"]?.enabled == true)
        // В Little Snitch обе группы показаны снятой галочкой
        #expect(groups["Require VPN Services Local"]?.enabled == false)
        #expect(groups["Require VPN Services"]?.enabled == false)
    }

    @Test("Вид: встроенные, локальная, подписка")
    func parsesKinds() throws {
        let groups = byName(try RuleGroupModelParser.parse(model))
        #expect(groups["macOS Services"]?.kind == .builtin)
        #expect(groups["iCloud Services"]?.kind == .builtin)
        #expect(groups["Require VPN Services Local"]?.kind == .local)
        #expect(groups["Require VPN Services"]?.kind == .remote)
    }

    /// Допущение (design.md, Решение 3): пользовательское имя переименованной
    /// подписки лежит в `customName`. Проверяется живой приёмкой.
    @Test("Переименованная подписка — под пользовательским именем")
    func renamedSubscriptionUsesCustomName() throws {
        let renamed = Data("""
        {"groups": {"pykpmH": {"type": "loadedFromURL", "isActive": true,
                               "factoryName": "Require VPN Services",
                               "customName": "VPN Guard"}}}
        """.utf8)
        let groups = try RuleGroupModelParser.parse(renamed)
        #expect(groups == [RuleGroupInfo(name: "VPN Guard", enabled: true, kind: .remote)])
    }

    /// В июльском снимке у той же локальной группы ключа `type` не было,
    /// в сентябрьском — `loadedFromFile`: на `type` локальных не опираемся.
    @Test("Локальная группа находится и без type, и с незнакомым type")
    func localGroupRegardlessOfType() throws {
        let withoutType = Data(#"{"groups": {"ghoGzc": {"userProvidedName": "VPN down"}}}"#.utf8)
        #expect(try RuleGroupModelParser.parse(withoutType)
            == [RuleGroupInfo(name: "VPN down", enabled: false, kind: .local)])

        let unknownType = Data("""
        {"groups": {"ghoGzc": {"type": "somethingNew", "userProvidedName": "VPN down",
                               "isActive": true}}}
        """.utf8)
        #expect(try RuleGroupModelParser.parse(unknownType)
            == [RuleGroupInfo(name: "VPN down", enabled: true, kind: .local)])
    }

    @Test("Внутренние идентификаторы наружу не попадают")
    func hidesInternalIdentifiers() throws {
        let groups = try RuleGroupModelParser.parse(model)
        #expect(!groups.contains {
            $0.name.hasPrefix("aaaaa") || $0.name == "ghoGzc" || $0.name == "pykpmH"
        })
    }

    @Test("Безымянная запись неизвестного типа пропускается, а не выдумывается")
    func skipsNamelessUnknownType() throws {
        let unknown = Data("""
        {"groups": {"zzz": {"type": "builtinSomethingNew", "isActive": true},
                    "ghoGzc": {"userProvidedName": "VPN down", "isActive": true}}}
        """.utf8)
        let groups = try RuleGroupModelParser.parse(unknown)
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: true, kind: .local)])
    }

    /// Одноимённые локальная и подписка не схлопываются в helper: их разводит
    /// приложение с предупреждением в журнал. Порядок фиксирован — локальная
    /// первой, чтобы «первая из одноимённых» была одной и той же.
    @Test("Одноимённые локальная и подписка — две записи в фиксированном порядке")
    func keepsSameNamedLocalAndRemote() throws {
        let collision = Data("""
        {"groups": {"b": {"type": "loadedFromURL", "factoryName": "VPN down",
                          "isActive": true},
                    "a": {"userProvidedName": "VPN down"}}}
        """.utf8)
        let groups = try RuleGroupModelParser.parse(collision)
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: false, kind: .local),
                           RuleGroupInfo(name: "VPN down", enabled: true, kind: .remote)])
    }

    @Test("Пустая модель без групп даёт внятную ошибку")
    func emptyModelFails() {
        #expect(throws: RuleGroupModelParser.ParseFailure.self) {
            try RuleGroupModelParser.parse(Data(#"{"groups": {}, "rules": []}"#.utf8))
        }
    }
}
