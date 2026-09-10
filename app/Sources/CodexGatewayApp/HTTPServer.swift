import Foundation
import Network
import CryptoKit

final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    typealias Handler = (Request, HTTPConnection) async -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codexgateway.http")
    private let handler: Handler
    private var clients: [UUID: (HTTPConnection, Task<Void, Never>)] = [:]
    private var readiness: CheckedContinuation<Void, Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readiness = continuation
                self.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: self.readiness?.resume(); self.readiness = nil
                    case .failed(let error), .waiting(let error):
                        self.readiness?.resume(throwing: error); self.readiness = nil
                        self.listener.cancel()
                    case .cancelled:
                        self.cancelled = true
                        self.stopWaiters.forEach { $0.resume() }; self.stopWaiters.removeAll()
                        self.readiness?.resume(throwing: CancellationError()); self.readiness = nil
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { connection in
                    let id = UUID()
                    let client = HTTPConnection(connection: connection)
                    connection.start(queue: self.queue)
                    let task = Task {
                        do {
                            let request = try await client.readRequest()
                            await self.handler(request, client)
                        } catch {
                            if !client.started { try? await client.json(400, ["error": ["message": "Invalid HTTP request"]]) }
                        }
                        client.close()
                        self.queue.async { self.clients.removeValue(forKey: id) }
                    }
                    self.clients[id] = (client, task)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.cancelled { continuation.resume(); return }
                self.stopWaiters.append(continuation)
                self.listener.cancel()
                for (client, task) in self.clients.values { task.cancel(); client.close() }
                self.clients.removeAll()
            }
        }
    }
}

final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = Data()
    private(set) var started = false
    private let maxBody = 64 * 1024 * 1024
    init(connection: NWConnection) { self.connection = connection }
    func close() { connection.cancel() }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func receive() async throws {
        try Task.checkCancellation()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: URLError(complete ? .networkConnectionLost : .badServerResponse)) }
            }
        }
        buffer.append(data)
    }
    private func take(_ count: Int) async throws -> Data {
        guard count >= 0, count <= maxBody else { throw URLError(.dataLengthExceedsMaximum) }
        while buffer.count < count { try await receive() }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count)
        return data
    }
    private func line() async throws -> String {
        while buffer.range(of: Data("\r\n".utf8)) == nil {
            guard buffer.count < 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            try await receive()
        }
        let end = buffer.range(of: Data("\r\n".utf8))!
        let value = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        return value
    }
    func readRequest() async throws -> HTTPServer.Request {
        let first = try await line().split(separator: " ")
        guard first.count == 3 else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        var total = 0
        while true {
            let value = try await line(); total += value.utf8.count
            guard total < 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            if value.isEmpty { break }
            guard let colon = value.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let name = value[..<colon].lowercased()
            guard headers[name] == nil else { throw URLError(.badServerResponse) }
            headers[name] = value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["expect"]?.lowercased() == "100-continue" { try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        var body = Data()
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw URLError(.badServerResponse) }
            while true {
                let sizeLine = try await line().split(separator: ";", maxSplits: 1)
                guard let value = sizeLine.first, let size = Int(value, radix: 16), size >= 0,
                      size <= maxBody - body.count else { throw URLError(.dataLengthExceedsMaximum) }
                if size == 0 {
                    var trailerSize = 0
                    while true {
                        let trailer = try await line(); trailerSize += trailer.utf8.count
                        guard trailerSize < 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                        if trailer.isEmpty { break }
                    }
                    break
                }
                body.append(try await take(size))
                guard try await take(2) == Data("\r\n".utf8) else { throw URLError(.badServerResponse) }
            }
        } else if let length = headers["content-length"] {
            guard let count = Int(length) else { throw URLError(.badServerResponse) }
            body = try await take(count)
        }
        return HTTPServer.Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    func begin(_ status: Int, headers: [String: String]) async throws {
        guard !started else { return }
        started = true
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nConnection: close\r\n"
        let excluded: Set<String> = ["connection", "transfer-encoding", "content-length", "content-encoding", "keep-alive", "trailer"]
        for (key, value) in headers where !excluded.contains(key.lowercased()) && !value.contains("\r") && !value.contains("\n") {
            head += "\(key): \(value)\r\n"
        }
        try await send(Data((head + "\r\n").utf8))
    }
    func json(_ status: Int, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await begin(status, headers: ["Content-Type": "application/json"])
        try await send(data)
    }

    func upgradeWebSocket(key: String) async throws {
        let hash = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(hash).base64EncodedString()
        started = true
        try await send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
    }
    func sendWebSocket(_ payload: Data, opcode: UInt8 = 1) async throws {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 65535 {
            frame.append(126); frame.append(UInt8((payload.count >> 8) & 255)); frame.append(UInt8(payload.count & 255))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        }
        frame.append(payload); try await send(frame)
    }
    func readWebSocket() async throws -> (Data, UInt8)? {
        var message = Data(), messageOpcode: UInt8 = 0
        while true {
            let header = [UInt8](try await take(2))
            let opcode = header[0] & 15, final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 != 0 else { throw URLError(.badServerResponse) }
            var length = UInt64(header[1] & 127)
            if length == 126 { length = try await take(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            else if length == 127 { length = try await take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            guard length <= maxBody - message.count else { throw URLError(.dataLengthExceedsMaximum) }
            let mask = [UInt8](try await take(4)), raw = [UInt8](try await take(Int(length)))
            let payload = Data(raw.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            if opcode >= 8 {
                guard final, length <= 125 else { throw URLError(.badServerResponse) }
                if opcode == 8 { try await sendWebSocket(payload, opcode: 8); return nil }
                if opcode == 9 { try await sendWebSocket(payload, opcode: 10) }
                continue
            }
            if opcode != 0 {
                guard messageOpcode == 0, opcode == 1 || opcode == 2 else { throw URLError(.badServerResponse) }
                messageOpcode = opcode
            } else if messageOpcode == 0 { throw URLError(.badServerResponse) }
            message.append(payload)
            if final { return (message, messageOpcode) }
        }
    }
}
