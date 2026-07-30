import Foundation

/// Узкий XPC-контракт helper-демона (§10.2 SPEC.md): ровно три операции,
/// произвольные команды не проходят по построению. Файл компилируется
/// и в приложение, и в helper.
@objc protocol HelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    /// JSON-массив [{"name": String, "enabled": Bool}] либо (nil, описание ошибки)
    func listRuleGroups(reply: @escaping @Sendable (Data?, String?) -> Void)
    func setRuleGroup(_ name: String, enabled: Bool,
                      reply: @escaping @Sendable (Bool, String?) -> Void)
}

enum HelperConstants {
    static let machServiceName = "dev.sunnyday.lsvpncompanion.helper"
    static let marketingVersion = "1.0"
    static let littlesnitchPath =
        "/Applications/Little Snitch.app/Contents/Components/littlesnitch"
    static let helperExecutableName = "dev.sunnyday.lsvpncompanion.helper"

    /// Путь к собственному исполняемому файлу. `argv[0]` для launchd-демона
    /// путём не является, а `Bundle.main` внутри бандла приложения указывает
    /// на бинарь приложения — оба варианта давали неверную версию.
    static func currentExecutablePath() -> String {
        var size = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return CommandLine.arguments.first ?? ""
        }
        let path = String(cString: buffer)
        return (path as NSString).resolvingSymlinksInPath
    }

    /// Версия helper включает отпечаток самого бинаря: launchd держит демон в
    /// памяти, поэтому после пересборки в системе может работать устаревший
    /// helper. Приложение сравнивает эту строку с отпечатком бинаря в своём
    /// бандле и переустанавливает демон, если они разошлись.
    static func version(ofExecutableAt path: String) -> String {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { $0[.modificationDate] as? Date }
            .map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "\(marketingVersion) (build \(stamp))"
    }
}
