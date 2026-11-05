import Foundation

struct StatusClient: Sendable {
    var endpoint: StatusEndpoint?
    var timeout = 3.0

    /// Синхронный вызов для CLI; из async-кода выполняется на отдельной очереди.
    func read(detectorID: String?) throws -> StatusDocument {
        let deadline = StatusSocket.deadline(seconds: timeout)
        let socket = try StatusSocket()
        defer { socket.closeSocket() }
        try socket.connect(to: endpoint ?? StatusEndpoint.current(), until: deadline)
        let request = try JSONEncoder().encode(StatusRequest(detectorID: detectorID))
        try socket.writeFrame(request, limit: StatusSocket.requestLimit, until: deadline)
        let data = try socket.readFrame(limit: StatusSocket.responseLimit, until: deadline)
        let document: StatusDocument
        do { document = try JSONDecoder().decode(StatusResponse.self, from: data).document(detectorID: detectorID) }
        catch let failure as StatusFailure { throw failure }
        catch { throw StatusFailure.protocolError }
        try StatusSocket.checkDeadline(deadline)
        return document
    }
}
