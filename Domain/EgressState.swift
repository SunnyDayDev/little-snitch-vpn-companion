/// Состояния домена (§5 SPEC.md). Флаг «helper недоступен» ортогонален
/// состоянию и живёт в `StateMachine` отдельно.
enum EgressState: String, Codable, Hashable, CaseIterable {
    case protected
    case leak
    case offline
    /// «Сеть есть, вердикта ещё нет». Возникает только в строгом режиме:
    /// в реактивном состояние до вердикта сохраняется прежним.
    case checking
    case paused
}

/// Режим защиты (ФТ-2): каким ситуациям разрешено держать трафик открытым.
enum ProtectionMode: String, Codable, Hashable, CaseIterable {
    /// Закрываем при доказанной утечке; неопределённость групп не трогает.
    case reactive
    /// Открыто только при доказанном VPN: любая неопределённость закрывает.
    case strict
}

/// Момент времени без Foundation: Domain остаётся чистым Swift, а реальные
/// часы приходят через порт `Clock` из Application-слоя.
struct Instant: Hashable, Comparable, Codable {
    let secondsSinceEpoch: Double

    init(secondsSinceEpoch: Double) {
        self.secondsSinceEpoch = secondsSinceEpoch
    }

    static func < (lhs: Instant, rhs: Instant) -> Bool {
        lhs.secondsSinceEpoch < rhs.secondsSinceEpoch
    }

    func adding(seconds: Double) -> Instant {
        Instant(secondsSinceEpoch: secondsSinceEpoch + seconds)
    }

    func seconds(since earlier: Instant) -> Double {
        secondsSinceEpoch - earlier.secondsSinceEpoch
    }
}
