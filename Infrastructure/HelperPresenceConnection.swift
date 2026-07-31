import Foundation
import os

/// Presence-соединение строгого режима (D5): постоянное XPC-соединение к
/// helper, самим фактом жизни сообщающее «приложение живо» его супервизии.
/// Отдельное от ленивого соединения gateway: то сбрасывается таймаутами и
/// переустановками и в индикаторы жизни не годится.
actor HelperPresenceConnection {
    private var connection: NSXPCConnection?
    private var isActive = false
    private let logger = Logger(subsystem: "dev.sunnyday.lsvpncompanion",
                                category: "helper-presence")

    /// Включается ровно при активном строгом режиме (strict и не observeOnly).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            establish()
        } else {
            // Сначала сбросить ссылку: invalidation-обработчик не должен
            // переустановить соединение, которое мы сами и закрыли.
            let closing = connection
            connection = nil
            closing?.invalidate()
        }
    }

    private func establish() {
        guard isActive else { return }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Немедленная переустановка (D5): пауза дольше таймаута супервизии
        // выглядела бы для helper как крэш приложения.
        connection.invalidationHandler = { [weak self] in
            Task { await self?.reestablish() }
        }
        // Прерывание — helper перезапустился: соединение живо, но новый
        // процесс демона этого клиента ещё не считал. Представляемся заново.
        connection.interruptionHandler = { [weak self] in
            Task { await self?.poke() }
        }
        connection.resume()
        self.connection = connection
        logger.debug("presence-соединение установлено")
        poke()
    }

    private func reestablish() async {
        guard isActive else { return }
        connection = nil
        // Секундная пауза против плотного цикла invalidation, пока helper не
        // установлен или не одобрен: секунда ≪ таймаута супервизии.
        try? await Task.sleep(for: .seconds(1))
        guard isActive, connection == nil else { return }
        establish()
    }

    /// XPC устанавливает соединение лениво: без единого сообщения helper не
    /// узнает о клиенте. `version` — самый дешёвый способ представиться.
    private func poke() {
        guard isActive, let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? any HelperProtocol)?.version { _ in }
    }
}
