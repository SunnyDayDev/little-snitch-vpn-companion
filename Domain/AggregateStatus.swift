/// Сводное состояние для иконки строки меню и шапки поповера (D11
/// design.md): худшее среди включённых детекторов в порядке Leak > Checking >
/// Offline > Protected; Paused, когда мониторинг на паузе; без включённых
/// детекторов — Offline с признаком «детекторов нет».
struct AggregateStatus: Hashable, Sendable {
    /// Детектор глазами сводки.
    struct Member: Hashable, Sendable {
        let id: DetectorID
        let isEnabled: Bool
        let mode: ProtectionMode
        let state: EgressState

        init(id: DetectorID, isEnabled: Bool = true, mode: ProtectionMode, state: EgressState) {
            self.id = id
            self.isEnabled = isEnabled
            self.mode = mode
            self.state = state
        }
    }

    let state: EgressState
    /// Детектор-виновник: первый включённый с худшим состоянием, когда оно
    /// хуже Protected. Заголовок поповера называет его, баннер — о нём.
    let culprit: DetectorID?
    let hasEnabledDetectors: Bool
    /// Есть включённый строгий детектор в Offline или Checking: трафик по его
    /// пути закрыт без утечки — warn-акцент иконки вместо монохрома.
    let hasStrictClosed: Bool

    init(state: EgressState, culprit: DetectorID? = nil,
         hasEnabledDetectors: Bool = true, hasStrictClosed: Bool = false) {
        self.state = state
        self.culprit = culprit
        self.hasEnabledDetectors = hasEnabledDetectors
        self.hasStrictClosed = hasStrictClosed
    }

    static func summarize(_ members: [Member], isPaused: Bool) -> AggregateStatus {
        let enabled = members.filter(\.isEnabled)
        let strictClosed = enabled.contains {
            $0.mode == .strict && ($0.state == .offline || $0.state == .checking)
        }
        if isPaused {
            return AggregateStatus(state: .paused,
                                   hasEnabledDetectors: !enabled.isEmpty,
                                   hasStrictClosed: false)
        }
        guard let worst = enabled.max(by: { severity($0.state) < severity($1.state) }) else {
            return AggregateStatus(state: .offline, hasEnabledDetectors: false)
        }
        // `max(by:)` отдаёт последний из равных — виновником берём первого.
        let culprit = enabled.first { severity($0.state) == severity(worst.state) }
        let state = normalized(worst.state)
        return AggregateStatus(state: state,
                               culprit: state == .protected ? nil : culprit?.id,
                               hasEnabledDetectors: true,
                               hasStrictClosed: strictClosed)
    }

    /// Paused у отдельной машины вне общей паузы — переходный миг (детектор
    /// включён, вердикта ещё нет): в сводке он «без вердикта», как Offline.
    private static func normalized(_ state: EgressState) -> EgressState {
        state == .paused ? .offline : state
    }

    private static func severity(_ state: EgressState) -> Int {
        switch state {
        case .leak: 3
        case .checking: 2
        case .offline, .paused: 1
        case .protected: 0
        }
    }
}
