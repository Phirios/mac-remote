import Foundation
import Network

/// WebSocket server built on `Network.framework` (no external deps).
///
/// One listener accepts connections. Each connection runs a small state
/// machine: HTTP upgrade → token validation → frame loop. Incoming text
/// frames are decoded as `MRMessage` and forwarded to the injector.
///
/// All callbacks land on the main actor; the injector is main-actor-bound.
final class WSServer {
    let port: NWEndpoint.Port
    private let token: String
    private let onMessage: @MainActor (MRMessage) -> Void
    private let onConnectionChange: @MainActor (Int) -> Void   // active connection count

    private var listener: NWListener?
    private var connections: Set<WSConnection> = []
    private let queue = DispatchQueue(label: "mac-remote.ws")

    init(port: UInt16,
         token: String,
         onMessage: @MainActor @escaping (MRMessage) -> Void,
         onConnectionChange: @MainActor @escaping (Int) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.token = token
        self.onMessage = onMessage
        self.onConnectionChange = onConnectionChange
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let err): NSLog("[WSServer] listener failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func broadcast(_ msg: MRMessage) {
        guard let text = try? MRCodec.encodeString(msg) else { return }
        let frame = WSFrame.text(text)
        queue.async { [weak self] in
            self?.connections.forEach { $0.sendFrame(frame) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections { c.close() }
        connections.removeAll()
    }

    private func accept(_ conn: NWConnection) {
        let wrapper = WSConnection(
            conn: conn,
            queue: queue,
            token: token,
            onMessage: { [weak self] msg in
                guard let self else { return }
                Task { @MainActor in self.onMessage(msg) }
            },
            onClosed: { [weak self] c in
                guard let self else { return }
                self.queue.async {
                    self.connections.remove(c)
                    let count = self.connections.count
                    Task { @MainActor in self.onConnectionChange(count) }
                }
            }
        )
        connections.insert(wrapper)
        let count = connections.count
        Task { @MainActor in onConnectionChange(count) }
        wrapper.start()
    }
}

// MARK: - Per-connection state machine

final class WSConnection: Hashable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let onMessage: (MRMessage) -> Void
    private let onClosed: (WSConnection) -> Void

    private enum State { case awaitingHTTP, websocket, closed }
    private var state: State = .awaitingHTTP
    private var rxBuffer = Data()

    init(conn: NWConnection, queue: DispatchQueue, token: String,
         onMessage: @escaping (MRMessage) -> Void,
         onClosed: @escaping (WSConnection) -> Void) {
        self.conn = conn
        self.queue = queue
        self.token = token
        self.onMessage = onMessage
        self.onClosed = onClosed
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.fail()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        conn.cancel()
    }

    private func fail() {
        guard state != .closed else { return }
        state = .closed
        onClosed(self)
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.fail()
                return
            }
            if self.state != .closed { self.receive() }
        }
    }

    // MARK: HTTP upgrade

    private func process() {
        switch state {
        case .awaitingHTTP:
            // Wait until we have the full header section
            guard rxBuffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
            guard let req = HTTPRequest.parse(rxBuffer) else { rejectAndClose(400, "Bad Request"); return }
            rxBuffer.removeAll(keepingCapacity: true)
            handleUpgrade(req)
        case .websocket:
            processFrames()
        case .closed:
            return
        }
    }

    private func handleUpgrade(_ req: HTTPRequest) {
        // Validate token from URL path.
        let pathToken = req.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard pathToken == token else {
            NSLog("[WSConnection] auth rejected (bad token)")
            rejectAndClose(401, "Unauthorized")
            return
        }
        guard req.headers["upgrade"]?.lowercased() == "websocket",
              let key = req.headers["sec-websocket-key"] else {
            rejectAndClose(400, "Bad Request")
            return
        }
        let response = WSHandshake.upgradeResponse(clientKey: key)
        send(raw: response) { [weak self] in
            self?.state = .websocket
        }
    }

    private func rejectAndClose(_ code: Int, _ reason: String) {
        let body = "\(code) \(reason)\n"
        let resp = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        send(raw: Data(resp.utf8)) { [weak self] in
            self?.close()
            self?.onClosed(self!)
        }
    }

    // MARK: WebSocket frame loop

    private func processFrames() {
        while state == .websocket {
            guard let (frame, consumed) = WSFrame.parse(rxBuffer) else { return }
            rxBuffer.removeFirst(consumed)
            handle(frame)
        }
    }

    private func handle(_ frame: WSFrame) {
        switch frame.opcode {
        case .text:
            do {
                let msg = try MRCodec.decode(frame.payload)
                onMessage(msg)
            } catch {
                NSLog("[WSConnection] bad payload: \(error)")
            }
        case .ping:
            send(frame: .pong(frame.payload))
        case .close:
            send(frame: .close())
            close()
            onClosed(self)
        case .pong, .binary, .continuation:
            break
        }
    }

    // MARK: send

    func sendFrame(_ frame: WSFrame) {
        send(raw: frame.encode(), then: nil)
    }

    private func send(frame: WSFrame) {
        send(raw: frame.encode(), then: nil)
    }

    private func send(raw: Data, then: (() -> Void)? = nil) {
        conn.send(content: raw, completion: .contentProcessed { _ in then?() })
    }

    // Hashable
    static func == (l: WSConnection, r: WSConnection) -> Bool { l === r }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
