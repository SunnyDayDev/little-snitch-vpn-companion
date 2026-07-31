import Foundation
import os

// Привилегированный helper-демон (LaunchDaemon, root). Единственный компонент,
// вызывающий littlesnitch CLI.

let logger = Logger(subsystem: HelperConstants.machServiceName, category: "main")
let helperVersion = HelperConstants.version(
    ofExecutableAt: HelperConstants.currentExecutablePath())
logger.log("helper \(helperVersion, privacy: .public) запущен")

// Failsafe (D5): конфиг читается с диска до подъёма listener — супервизор
// знает режим и группы, не дожидаясь синхронизации от приложения.
let failsafeStore = FailsafeStore()
let supervisor = FailsafeSupervisor(
    config: failsafeStore.load() ?? .inactive,
    timer: DispatchFailsafeTimer(),
    closeGroups: closeGroupsForFailsafe)

let delegate = HelperListenerDelegate(failsafe: failsafeStore, supervisor: supervisor)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// Эшелон 4 (задача 5.2; спайк 5.1: RunAtLoad стартует при uptime ~40 с, CLI
// отвечает через ~1 с): на загрузке ОС при активном строгом режиме группы
// закрываются до логина и старта приложения. Закрывает и окно «аварийное
// выключение при открытых группах».
let bootConfig = failsafeStore.load() ?? .inactive
let versionForBoot = helperVersion
DispatchQueue.global(qos: .userInitiated).async {
    runBootClose(config: bootConfig, version: versionForBoot)
}

dispatchMain()

/// Закрытие на загрузке. Итог пишется и в os_log, и в boot-probe.log рядом с
/// конфигом: unified log с обычного терминала не читается (нужен Full Disk
/// Access), а файл можно смотреть cat'ом при приёмке.
func runBootClose(config: FailsafeConfig, version: String) {
    let logger = Logger(subsystem: HelperConstants.machServiceName, category: "boot-close")
    let uptime = ProcessInfo.processInfo.systemUptime
    var lines = ["--- helper \(version) запущен: \(Date()) · uptime \(Int(uptime)) с"]
    defer {
        appendBootLog(lines)
        logger.log("boot-close: \(lines.joined(separator: " | "), privacy: .public)")
    }

    guard BootClosePolicy.shouldClose(config: config, uptimeSeconds: uptime) else {
        lines.append(config.strictActive
            ? "закрытие пропущено: перезапуск демона посреди сессии (uptime выше порога)"
            : "закрытие не требуется: строгий режим неактивен")
        return
    }

    // Ждём готовности CLI с нарастающим шагом: на загрузке Little Snitch
    // может подниматься параллельно с нами.
    let cli = LittleSnitchCLI()
    let begin = Date()
    var delay = 2.0
    while true {
        if (try? cli.exportModel()) != nil { break }
        if Date().timeIntervalSince(begin) > 600 {
            lines.append("CLI не ответил за 10 мин — закрытие на загрузке не выполнено")
            return
        }
        Thread.sleep(forTimeInterval: delay)
        delay = min(delay * 2, 60)
    }

    closeGroupsForFailsafe(config.groups)
    lines.append("строгий режим: группы закрыты на загрузке через "
        + "\(Int(Date().timeIntervalSince(begin))) с (\(config.groups.joined(separator: ", ")))")
}

private func appendBootLog(_ lines: [String]) {
    let dir = URL(fileURLWithPath: "/Library/Application Support/dev.sunnyday.lsvpncompanion.helper",
                  isDirectory: true)
    let file = dir.appendingPathComponent("boot-probe.log")
    let entry = lines.joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    try? (existing + entry).write(to: file, atomically: true, encoding: .utf8)
}

/// Dead-man's switch сработал: приложение исчезло при активном строгом
/// режиме — включаем группы сами. Три попытки на группу: CLI может моргнуть,
/// а второго шанса у страховки нет. Логгер свой: глобальный изолирован на
/// MainActor top-level кода, а сюда приходит очередь таймера.
func closeGroupsForFailsafe(_ groups: [String]) {
    let logger = Logger(subsystem: HelperConstants.machServiceName, category: "failsafe")
    let cli = LittleSnitchCLI()
    var outcomes: [String] = []
    for group in groups {
        for attempt in 1...3 {
            do {
                try cli.setRuleGroup(group, enabled: true)
                logger.log("failsafe: группа «\(group, privacy: .public)» включена")
                outcomes.append("«\(group)» включена (попытка \(attempt))")
                break
            } catch {
                logger.error("""
                    failsafe: попытка \(attempt, privacy: .public) для \
                    «\(group, privacy: .public)»: \(String(describing: error), privacy: .public)
                    """)
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 2)
                } else {
                    outcomes.append("«\(group)» НЕ включена: \(error)")
                }
            }
        }
    }
    // Тот же файл, что у boot-close: приёмка dead-man's switch без Full Disk
    // Access для unified log.
    appendBootLog(["--- dead-man's switch: \(Date())"] + outcomes)
}
