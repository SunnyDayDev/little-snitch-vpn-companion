/// Запись журнала (ФТ-6): время, триггер, egress-IP, событие, действие.
struct JournalEvent: Hashable, Codable {
    enum Kind: Hashable, Codable {
        case transition(from: EgressState, to: EgressState)
        case action(String)
        case error(String)
        case warning(String)
        case fact(String)

        /// Категории фильтра окна журнала: Все / Переходы / Действия / Ошибки.
        var category: Category {
            switch self {
            case .transition: .transition
            case .action: .action
            case .error: .error
            case .warning, .fact: .fact
            }
        }
    }

    enum Category: String, Codable, Hashable, CaseIterable {
        case transition, action, error, fact
    }

    let time: Instant
    let trigger: ProbeTrigger?
    let egressIP: String?
    let kind: Kind
    /// Что сделали с группами: человекочитаемая строка для журнала.
    let action: String?

    init(time: Instant,
         trigger: ProbeTrigger? = nil,
         egressIP: String? = nil,
         kind: Kind,
         action: String? = nil) {
        self.time = time
        self.trigger = trigger
        self.egressIP = egressIP
        self.kind = kind
        self.action = action
    }
}
