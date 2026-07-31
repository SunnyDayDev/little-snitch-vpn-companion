import Foundation
import Testing

/// Персист failsafe-конфига — единственная память helper между перезапусками
/// (D5): roundtrip обязан быть точным, а битый или отсутствующий файл — не
/// ронять демон и читаться как «failsafe неактивен».
@Suite("Персист failsafe-конфига")
struct FailsafeStoreTests {
    /// Свой временный каталог на тест: боевой путь требует root.
    private static func temporaryStore() -> FailsafeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failsafe-tests-\(UUID().uuidString)", isDirectory: true)
        return FailsafeStore(fileURL: directory.appendingPathComponent("failsafe.json"))
    }

    private static func cleanup(_ store: FailsafeStore) {
        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    @Test("Roundtrip: сохранённый конфиг читается тем же")
    func roundtrip() throws {
        let store = Self.temporaryStore()
        defer { Self.cleanup(store) }
        let config = FailsafeConfig(strictActive: true,
                                    groups: ["VPN down", "Блок рекламы"],
                                    supervisionTimeoutSeconds: 30)
        try store.save(config)
        #expect(store.load() == config)
    }

    @Test("Повторная запись перезаписывает конфиг целиком")
    func overwrite() throws {
        let store = Self.temporaryStore()
        defer { Self.cleanup(store) }
        try store.save(FailsafeConfig(strictActive: true, groups: ["VPN down"]))
        try store.save(.inactive)
        #expect(store.load() == .inactive)
    }

    @Test("Файла нет → nil без ошибок")
    func missingFile() {
        let store = Self.temporaryStore()
        #expect(store.load() == nil)
    }

    @Test("Повреждённый JSON → nil, helper не падает")
    func corruptedJSON() throws {
        let store = Self.temporaryStore()
        defer { Self.cleanup(store) }
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{это не json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test("Таймаут в JSON не обязателен — подставляется дефолт")
    func defaultTimeout() throws {
        let store = Self.temporaryStore()
        defer { Self.cleanup(store) }
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"strictActive": true, "groups": ["VPN down"]}"#.utf8)
            .write(to: store.fileURL)
        let config = try #require(store.load())
        #expect(config.strictActive)
        #expect(config.supervisionTimeoutSeconds
            == FailsafeConfig.defaultSupervisionTimeoutSeconds)
    }
}

@Suite("Политика закрытия на загрузке")
struct BootClosePolicyTests {
    private let strict = FailsafeConfig(strictActive: true, groups: ["VPN down"])

    @Test("Закрывает на загрузке при активном строгом режиме")
    func closesAtBoot() {
        #expect(BootClosePolicy.shouldClose(config: strict, uptimeSeconds: 40))
    }

    @Test("Перезапуск демона посреди сессии не закрывает")
    func midSessionRestartIsQuiet() {
        // Переустановка helper при живом приложении со свежим Protected-вердиктом
        #expect(!BootClosePolicy.shouldClose(config: strict, uptimeSeconds: 7_200))
    }

    @Test("Неактивный строгий режим и пустые группы — тишина")
    func inactiveOrEmptyIsQuiet() {
        #expect(!BootClosePolicy.shouldClose(config: .inactive, uptimeSeconds: 40))
        #expect(!BootClosePolicy.shouldClose(
            config: FailsafeConfig(strictActive: true, groups: []), uptimeSeconds: 40))
    }
}
