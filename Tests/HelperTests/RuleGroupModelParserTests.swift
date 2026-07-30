import Foundation
import Testing

/// Формат `export-model` не документирован и может меняться с версиями LS,
/// поэтому парсер обязан находить группы в разных формах дерева и внятно
/// сообщать о неудаче вместо падения.
@Suite("Разбор модели Little Snitch")
struct RuleGroupModelParserTests {
    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    @Test("Плоский массив групп верхнего уровня")
    func parsesFlatArray() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": [
            {"name": "VPN down", "enabled": false},
            {"name": "Блок рекламы", "enabled": true}
        ]}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: false),
                           RuleGroupInfo(name: "Блок рекламы", enabled: true)])
    }

    @Test("Вложенное дерево: группы находятся на любой глубине")
    func parsesNested() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"model": {"config": {"ruleGroups": [
            {"name": "VPN down", "isEnabled": true, "rules": [{"action": "deny"}]}
        ]}}}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: true)])
    }

    @Test("Инвертированный признак: disabled вместо enabled")
    func parsesDisabledFlag() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": [{"name": "VPN down", "disabled": true}]}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: false)])
    }

    @Test("Объекты без булева признака группами не считаются")
    func ignoresNonGroups() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": [{"name": "VPN down", "enabled": false}],
         "rules": [{"name": "Правило без статуса", "action": "deny"}]}
        """))
        #expect(groups.map(\.name) == ["VPN down"])
    }

    /// Реальная модель LS (проверено на целевой машине) держит группы под
    /// ключом `groups`; форма значения не документирована, поэтому парсер
    /// понимает и словарь «имя → описание», где имени внутри нет.
    @Test("Словарь групп, ключ которого и есть имя")
    func parsesDictionaryKeyedByName() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": {
            "VPN down": {"enabled": false, "rules": []},
            "Блок-лист рекламы": {"enabled": true}
        }}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: false),
                           RuleGroupInfo(name: "Блок-лист рекламы", enabled: true)])
    }

    @Test("Словарь групп по UUID: имя берётся из описания")
    func parsesDictionaryKeyedByUUID() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": {
            "8B1C-441F": {"name": "VPN down", "isEnabled": true}
        }}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: true)])
    }

    @Test("Состояние строкой вместо булева флага")
    func parsesStringState() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": [{"name": "VPN down", "state": "disabled"},
                    {"name": "Соцсети", "state": "ENABLED"}]}
        """))
        #expect(groups == [RuleGroupInfo(name: "VPN down", enabled: false),
                           RuleGroupInfo(name: "Соцсети", enabled: true)])
    }

    @Test("Модель без групп → внятная ошибка с ключами верхнего уровня")
    func reportsMissingGroups() {
        #expect(throws: RuleGroupModelParser.ParseFailure.self) {
            try RuleGroupModelParser.parse(json(#"{"version": 6, "rules": []}"#))
        }
        do {
            _ = try RuleGroupModelParser.parse(json(#"{"version": 6, "rules": []}"#))
        } catch let failure as RuleGroupModelParser.ParseFailure {
            #expect(failure.topLevelKeys == ["rules", "version"])
            #expect(failure.description.contains("rules"))
        } catch {
            Issue.record("ожидался ParseFailure")
        }
    }

    @Test("Битый JSON не роняет helper")
    func handlesBrokenJSON() {
        #expect(throws: (any Error).self) {
            try RuleGroupModelParser.parse(json("не json вовсе"))
        }
    }

    @Test("Имена сортируются человекочитаемо, кириллица и латиница вперемешку")
    func sortsNames() throws {
        let groups = try RuleGroupModelParser.parse(json("""
        {"groups": [
            {"name": "Яндекс", "enabled": false},
            {"name": "Adobe", "enabled": false},
            {"name": "Блок", "enabled": false}
        ]}
        """))
        #expect(groups.map(\.name) == ["Adobe", "Блок", "Яндекс"])
    }
}
