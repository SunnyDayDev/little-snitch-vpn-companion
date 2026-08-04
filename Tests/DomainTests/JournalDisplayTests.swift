import Testing

@Suite("JournalDisplay — срез журнала для окна")
struct JournalDisplayTests {
    private func fact(_ text: String) -> JournalEvent {
        JournalEvent(time: Instant(secondsSinceEpoch: 0), kind: .fact(text))
    }

    private func error(_ text: String) -> JournalEvent {
        JournalEvent(time: Instant(secondsSinceEpoch: 0), kind: .error(text))
    }

    @Test("Фильтр достаёт редкую категорию из-за лимита показа")
    func filterReachesBeyondLimit() {
        // Ошибка недельной давности, за ней — шквал фактов длиннее лимита
        let events = [error("helper упал")] + (0..<30).map { fact("путь \($0)") }

        let slice = JournalDisplay.slice(of: events, category: .error, limit: 10)

        #expect(slice.events.map(\.kind) == [.error("helper упал")])
        #expect(slice.totalMatching == 1)
        #expect(!slice.isTruncated)
    }

    @Test("Лимит применяется после фильтра, новые первыми")
    func limitAppliesAfterFilter() {
        let events = (0..<25).flatMap { [error("ошибка \($0)"), fact("факт \($0)")] }

        let slice = JournalDisplay.slice(of: events, category: .error, limit: 10)

        // Последние 10 ошибок из 25, свежая — первой
        #expect(slice.events.count == 10)
        #expect(slice.totalMatching == 25)
        #expect(slice.isTruncated)
        #expect(slice.events.first?.kind == .error("ошибка 24"))
        #expect(slice.events.last?.kind == .error("ошибка 15"))
    }

    @Test("Без категории — все записи, новые первыми")
    func noCategoryShowsEverything() {
        let events = [fact("первый"), error("второй"), fact("третий")]

        let slice = JournalDisplay.slice(of: events, category: nil, limit: 10)

        #expect(slice.events.map(\.kind)
            == [.fact("третий"), .error("второй"), .fact("первый")])
        #expect(slice.totalMatching == 3)
        #expect(!slice.isTruncated)
    }

    @Test("Warning и fact — одна категория фильтра")
    func warningsCountAsFacts() {
        let events = [
            fact("факт"),
            JournalEvent(time: Instant(secondsSinceEpoch: 0), kind: .warning("тревога")),
        ]

        let slice = JournalDisplay.slice(of: events, category: .fact, limit: 10)

        #expect(slice.events.count == 2)
    }
}
