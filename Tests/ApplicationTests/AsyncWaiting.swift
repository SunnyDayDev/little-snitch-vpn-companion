/// Ожидание асинхронных событий в тестах: подписка на поток вместо опроса.
///
/// Опрос через `Task.yield()` недетерминирован. Тесты идут параллельно, и на
/// загруженном раннере фоновая задача может не получить такта за любое конечное
/// число yield'ов: ограниченный цикл выходит раньше события и валит тест
/// (флак `wakeWiringDelivers`, macOS 26), а неограниченный жжёт поток пула и
/// отбирает такты у той самой задачи, которую ждёт. Ожидание события такой
/// зависимости не имеет: вызывающий спит и просыпается ровно в момент события.

import Foundation

/// Ждёт первое событие потока. Возвращает nil, если за `timeoutSeconds` его не
/// случилось: сторож нужен, чтобы порванная проводка валила тест, а не вешала
/// прогон. Реальные часы работают только в провальной ветке — успех приходит
/// сразу по событию.
func firstEvent<Element: Sendable>(from stream: AsyncStream<Element>,
                                   timeoutSeconds: Double = 10) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            return nil
        }
        let first = await group.next() ?? nil
        // Проигравшую задачу снимаем: и итерация потока, и сон отменяемы —
        // иначе группа досиживала бы до конца сторожевого таймера.
        group.cancelAll()
        return first
    }
}

/// Ждёт снимок координатора, удовлетворяющий условию. Наблюдатель получает
/// текущий снимок сразу при подписке и дальше каждый publish, поэтому событие
/// не теряется, даже если условие выполнилось до подписки.
func waitForSnapshot(_ coordinator: MonitoringCoordinator,
                     timeoutSeconds: Double = 10,
                     where predicate: @escaping @Sendable (MonitoringSnapshot) -> Bool) async -> Bool {
    let (stream, continuation) = AsyncStream.makeStream(of: MonitoringSnapshot.self)
    let observer = await coordinator.observe { snapshot in
        if predicate(snapshot) { continuation.yield(snapshot) }
    }
    let matched = await firstEvent(from: stream, timeoutSeconds: timeoutSeconds) != nil
    await coordinator.removeObserver(observer)
    return matched
}
