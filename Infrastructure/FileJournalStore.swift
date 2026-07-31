import Foundation
import os

/// Журнал в JSONL (ФТ-6): одна запись — одна строка, дописывание без
/// перечитывания файла. Ротация — раз в сутки при первой записи: строки
/// старше 7 дней выбрасываются.
actor FileJournalStore: JournalStore {
    private let fileURL: URL
    private let retentionDays: Double
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion", category: "journal")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastRotation: Date?

    init(fileURL: URL? = nil, retentionDays: Double = 7) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.retentionDays = retentionDays
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("LittleSnitchVPNCompanion", isDirectory: true)
        return base.appendingPathComponent("journal.jsonl")
    }

    func append(_ event: JournalEvent) async {
        rotateIfNeeded()
        do {
            try ensureDirectory()
            var line = try encoder.encode(event)
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("не удалось записать журнал: \(String(describing: error), privacy: .public)")
        }
    }

    func recent(limit: Int) async -> [JournalEvent] {
        let events = readAll()
        return Array(events.suffix(limit))
    }

    func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Текстовый экспорт для кнопки «Экспорт» в окне журнала.
    func exportText() async -> String {
        readAll().map(Self.describe).joined(separator: "\n")
    }

    // MARK: - Файл

    private func ensureDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func readAll() -> [JournalEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(JournalEvent.self, from: Data(line.utf8))
            }
    }

    private func rotateIfNeeded() {
        let now = Date()
        if let lastRotation, now.timeIntervalSince(lastRotation) < 3600 { return }
        lastRotation = now

        let cutoff = now.addingTimeInterval(-retentionDays * 86_400).timeIntervalSince1970
        let events = readAll()
        let kept = events.filter { $0.time.secondsSinceEpoch >= cutoff }
        guard kept.count != events.count else { return }

        do {
            let lines = try kept.map { try encoder.encode($0) }
            var data = Data()
            for line in lines {
                data.append(line)
                data.append(0x0A)
            }
            try ensureDirectory()
            try data.write(to: fileURL, options: .atomic)
            logger.debug("ротация журнала: осталось \(kept.count, privacy: .public) записей")
        } catch {
            logger.error("ротация не удалась: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Форматирование

    static func describe(_ event: JournalEvent) -> String {
        let time = JournalFormatting.timestamp(event.time)
        var parts = [time]
        if let trigger = event.trigger { parts.append("[\(JournalFormatting.trigger(trigger))]") }
        parts.append(JournalFormatting.kind(event.kind))
        if let ip = event.egressIP { parts.append("egress \(ip)") }
        if let action = event.action { parts.append("— \(action)") }
        return parts.joined(separator: " ")
    }
}

/// Человекочитаемые подписи журнала — используются и в файле-экспорте,
/// и в окне журнала.
enum JournalFormatting {
    static func timestamp(_ instant: Instant) -> String {
        let date = Date(timeIntervalSince1970: instant.secondsSinceEpoch)
        return Self.formatter.string(from: date)
    }

    /// Только время — колонка «Время» в окне журнала (дата видна в экспорте).
    static func time(_ instant: Instant) -> String {
        let date = Date(timeIntervalSince1970: instant.secondsSinceEpoch)
        return Self.timeFormatter.string(from: date)
    }

    static func trigger(_ trigger: ProbeTrigger) -> String {
        switch trigger {
        case .startup: "старт"
        case .tripwire: "растяжка"
        case .path: "путь"
        case .scheduled: "проба"
        case .confirmation: "подтверждение"
        case .ruBeacon: "ру-маяк"
        case .user: "пользователь"
        }
    }

    static func state(_ state: EgressState) -> String {
        switch state {
        case .protected: "Защищено"
        case .leak: "Утечка"
        case .offline: "Офлайн"
        case .checking: "Проверка"
        case .paused: "Пауза"
        }
    }

    static func kind(_ kind: JournalEvent.Kind) -> String {
        switch kind {
        case .transition(let from, let to): "\(state(from)) → \(state(to))"
        case .action(let text): text
        case .error(let text): "ошибка: \(text)"
        case .warning(let text): "предупреждение: \(text)"
        case .fact(let text): text
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
