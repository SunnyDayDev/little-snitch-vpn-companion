/// Представление состояния helper (таблица спеки helper-lifecycle): кнопка,
/// её активность и действие, строка статуса с тоном, ссылка на Системные
/// настройки. Чистая функция состояния, общая для настроек, онбординга и
/// поповера — раньше экраны считали тексты порознь и однажды разошлись
/// («подключён · root» против «недоступен»).
struct HelperPresentation: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case install
        case reinstall
        case remove
    }

    enum Tone: Hashable, Sendable {
        case normal
        case warning
        case danger
        case ok
    }

    static let approvalLinkTitle = "Открыть Системные настройки…"

    let buttonTitle: String
    let isButtonEnabled: Bool
    /// Что делает кнопка; `nil`, пока она неактивна.
    let action: Action?
    let statusText: String
    let tone: Tone
    /// Ссылка «Открыть Системные настройки…» — часть строки статуса, а не
    /// кнопки: кнопка в этом состоянии удаляет регистрацию.
    let showsApprovalLink: Bool

    static func make(state: HelperState, now: Instant) -> HelperPresentation {
        switch state {
        case .notInstalled:
            HelperPresentation(buttonTitle: "Установить…", isButtonEnabled: true, action: .install,
                               statusText: "не установлен", tone: .normal, showsApprovalLink: false)
        case .notFound:
            HelperPresentation(buttonTitle: "Установить…", isButtonEnabled: false, action: nil,
                               statusText: "не найден в бандле — сборка повреждена", tone: .danger,
                               showsApprovalLink: false)
        case .awaitingApproval:
            HelperPresentation(buttonTitle: "Удалить…", isButtonEnabled: true, action: .remove,
                               statusText: "ждёт одобрения в Системных настройках", tone: .warning,
                               showsApprovalLink: true)
        case .working(let operation, let startedAt):
            Self.working(operation, elapsedSeconds: max(0, now.seconds(since: startedAt)))
        case .ready(let version):
            HelperPresentation(buttonTitle: "Удалить…", isButtonEnabled: true, action: .remove,
                               statusText: "v\(version) · подключён · root", tone: .normal,
                               showsApprovalLink: false)
        case .stale(let running, _):
            HelperPresentation(buttonTitle: "Переустановить…", isButtonEnabled: true, action: .reinstall,
                               statusText: "v\(running) · устарел, в бандле новее", tone: .warning,
                               showsApprovalLink: false)
        case .silent:
            HelperPresentation(buttonTitle: "Переустановить…", isButtonEnabled: true, action: .reinstall,
                               statusText: "зарегистрирован, но не отвечает", tone: .warning,
                               showsApprovalLink: false)
        }
    }

    private static func working(_ operation: HelperState.Operation,
                                elapsedSeconds: Double) -> HelperPresentation {
        let seconds = Int(elapsedSeconds)
        return switch operation {
        case .install:
            HelperPresentation(buttonTitle: "Устанавливаем…", isButtonEnabled: false, action: nil,
                               statusText: "устанавливаем: ждём launchd… \(seconds) с",
                               tone: .normal, showsApprovalLink: false)
        case .reinstall:
            HelperPresentation(buttonTitle: "Переустанавливаем…", isButtonEnabled: false, action: nil,
                               statusText: "переустанавливаем: ждём launchd… \(seconds) с",
                               tone: .normal, showsApprovalLink: false)
        case .remove:
            HelperPresentation(buttonTitle: "Удаляем…", isButtonEnabled: false, action: nil,
                               statusText: "снимаем регистрацию…", tone: .normal,
                               showsApprovalLink: false)
        }
    }
}
