import Foundation
import os

// Привилегированный helper-демон (LaunchDaemon, root). Единственный компонент,
// вызывающий littlesnitch CLI.

let logger = Logger(subsystem: HelperConstants.machServiceName, category: "main")
let helperVersion = HelperConstants.version(
    ofExecutableAt: HelperConstants.currentExecutablePath())
logger.log("helper \(helperVersion, privacy: .public) запущен")

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

dispatchMain()
