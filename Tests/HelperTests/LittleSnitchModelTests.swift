import Foundation
import Testing

/// Фактическая модель Little Snitch 6, снятая с целевой машины 2026-07-30.
/// Форма подтверждена диагностикой: `groups` — словарь «внутренний id →
/// описание», встроенные группы описаны `type`, пользовательские —
/// `userProvidedName`, `isActive` есть только у включённых.
@Suite("Модель Little Snitch 6")
struct LittleSnitchModelTests {
    private let model = Data("""
    {
      "bundleVersion": "6.4",
      "profiles": {},
      "noProfilePseudoProfile": {"name": ""},
      "groups": {
        "aaaaac": {"type": "builtinMacOSServices", "isActive": true,
                   "updateInterval": 86400},
        "aaaaad": {"type": "builtinICloudServices", "isActive": true,
                   "updateInterval": 86400},
        "ghoGzc": {"userProvidedName": "Require VPN Services",
                   "creationDate": "2026-07-29T18:00:00Z", "updateInterval": 86400}
      },
      "rules": []
    }
    """.utf8)

    @Test("Имена: пользовательское из userProvidedName, встроенные — по type")
    func parsesNames() throws {
        let groups = try RuleGroupModelParser.parse(model)
        #expect(groups.map(\.name) == ["iCloud Services", "macOS Services",
                                       "Require VPN Services"])
    }

    @Test("Отсутствие isActive означает «выключена», а не «неизвестно»")
    func missingIsActiveMeansDisabled() throws {
        let groups = try RuleGroupModelParser.parse(model)
        let byName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.enabled) })
        #expect(byName["macOS Services"] == true)
        #expect(byName["iCloud Services"] == true)
        // В Little Snitch эта группа показана снятой галочкой
        #expect(byName["Require VPN Services"] == false)
    }

    @Test("Внутренние идентификаторы наружу не попадают")
    func hidesInternalIdentifiers() throws {
        let groups = try RuleGroupModelParser.parse(model)
        #expect(!groups.contains { $0.name.hasPrefix("aaaaa") || $0.name == "ghoGzc" })
    }

    @Test("Группа неизвестного встроенного типа пропускается, а не выдумывается")
    func skipsUnknownBuiltinType() throws {
        let unknown = Data("""
        {"groups": {"zzz": {"type": "builtinSomethingNew", "isActive": true},
                    "ghoGzc": {"userProvidedName": "VPN down", "isActive": true}}}
        """.utf8)
        let groups = try RuleGroupModelParser.parse(unknown)
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: true)])
    }

    @Test("Пустая модель без групп даёт внятную ошибку")
    func emptyModelFails() {
        #expect(throws: RuleGroupModelParser.ParseFailure.self) {
            try RuleGroupModelParser.parse(Data(#"{"groups": {}, "rules": []}"#.utf8))
        }
    }
}
