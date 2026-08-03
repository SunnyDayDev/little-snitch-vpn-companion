/// Срез журнала для окна: фильтр категории применяется ко всей глубине
/// хранения ДО лимита показа — иначе шумные категории голодят редкие
/// (ошибка недельной давности не видна за фактами последних часов).
enum JournalDisplay {
    struct Slice: Hashable {
        /// Записи к показу, новые первыми.
        let events: [JournalEvent]
        /// Сколько всего записей категории в журнале — для подписи окна.
        let totalMatching: Int

        var isTruncated: Bool { events.count < totalMatching }
    }

    /// `events` — в порядке записи (старые первыми), как отдаёт хранилище.
    static func slice(of events: [JournalEvent],
                      category: JournalEvent.Category?,
                      limit: Int) -> Slice {
        let matching = category.map { wanted in
            events.filter { $0.kind.category == wanted }
        } ?? events
        return Slice(events: matching.suffix(limit).reversed(),
                     totalMatching: matching.count)
    }
}
