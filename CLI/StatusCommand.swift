import Foundation

struct StatusCommand: Sendable {
    var detectorID: String?
    var json = false
    var help = false

    static let usage = """
    Использование:
      lsvpn status [--detector <id>] [--json]
      lsvpn --help
      lsvpn status --help

    Показывает статус работающего приложения, без запуска новой проверки.
    --detector <id>  Выбрать детектор по полному ID из списка статуса.
    --json           Вывести JSON, также сочетается с --detector.
    Коды: 0 — прочитано; 1 — ошибка; 2 — аргументы; 3 — нет связи;
          4 — ID не найден; 5 — несовместимый ответ.
    """

    static func parse(_ arguments: [String]) throws -> StatusCommand {
        if arguments == ["--help"] || arguments == ["status", "--help"] { return StatusCommand(help: true) }
        guard arguments.first == "status" else { throw syntax() }
        var result = StatusCommand()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                guard !result.json else { throw syntax() }
                result.json = true
            case "--detector":
                index += 1
                guard result.detectorID == nil, index < arguments.count,
                      !arguments[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !arguments[index].hasPrefix("-") else { throw syntax() }
                result.detectorID = arguments[index]
            default: throw syntax()
            }
            index += 1
        }
        return result
    }
    private static func syntax() -> StatusFailure {
        StatusFailure(code: .usage, message: "Неверные аргументы. Используйте lsvpn status --help")
    }

    /// Результат собирается целиком: ошибка не оставляет частичный JSON в stdout.
    static func execute(_ arguments: [String],
                        read: (String?) throws -> StatusDocument) -> (code: Int32, stdout: String, stderr: String) {
        do {
            let command = try parse(arguments)
            if command.help { return (0, usage + "\n", "") }
            let document = try read(command.detectorID)
            try document.validate(detectorID: command.detectorID)
            let output: String
            if command.json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                output = String(decoding: try encoder.encode(document), as: UTF8.self)
            } else { output = StatusText.render(document) }
            return (0, output + "\n", "")
        } catch {
            let failure = error as? StatusFailure ?? StatusFailure(code: .failure, message: "Не удалось получить статус приложения")
            return (failure.code.rawValue, "", StatusText.safe(failure.message) + "\n")
        }
    }
}
