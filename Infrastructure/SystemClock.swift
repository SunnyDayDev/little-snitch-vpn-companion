import Foundation

/// Реальные часы. Domain и Application времени не знают — только этот порт.
struct SystemClock: Clock {
    func now() async -> Instant {
        Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
    }

    func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
