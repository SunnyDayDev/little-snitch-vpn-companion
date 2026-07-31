import Foundation

/// Персист failsafe-конфига: root-демон не может читать user defaults
/// приложения (D5), поэтому конфиг живёт своим JSON-файлом в
/// `/Library/Application Support/<label>/` и переживает перезапуски helper
/// и перезагрузку ОС. Путь инжектируется — логика тестируется во временном
/// каталоге без прав root.
struct FailsafeStore {
    static let defaultFileURL = URL(fileURLWithPath:
        "/Library/Application Support/\(HelperConstants.machServiceName)/failsafe.json")

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// `nil` — файла нет либо он повреждён. Повреждение не роняет helper и
    /// читается как «failsafe неактивен»: рабочий конфиг заново приедет от
    /// приложения при первой же синхронизации.
    func load() -> FailsafeConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FailsafeConfig.self, from: data)
    }

    func save(_ config: FailsafeConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        // Атомарно: прерванная записью перезагрузка не должна оставить битый
        // конфиг — он единственная память helper о строгом режиме.
        try data.write(to: fileURL, options: .atomic)
        // 0644 (владелец root:wheel достаётся от процесса-демона): конфиг
        // можно читать для диагностики, менять — только root.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }
}
