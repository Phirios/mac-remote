import Foundation

/// Minimal WebSocket client over URLSessionWebSocketTask with auto-reconnect.
final class WebSocketClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let onStatus: (ConnectionStatus) -> Void
    var onMessage: ((String) -> Void)?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pendingSend: [String] = []
    private var reconnectDelayMs = 500
    private var stopped = false

    init(url: URL, onStatus: @escaping (ConnectionStatus) -> Void) {
        self.url = url
        self.onStatus = onStatus
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func connect() {
        stopped = false
        onStatus(.connecting)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: []),
              let s = String(data: data, encoding: .utf8) else { return }
        if let task, task.state == .running {
            task.send(.string(s)) { _ in }
        } else {
            // Drop oldest if queue grows beyond a sane bound (only keeps user responsive on reconnect)
            if pendingSend.count > 200 { pendingSend.removeFirst(pendingSend.count - 200) }
            pendingSend.append(s)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.onMessage?(text) }
                self.receiveLoop()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        onStatus(.disconnected)
        let delay = reconnectDelayMs
        reconnectDelayMs = min(reconnectDelayMs * 2, 5000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        reconnectDelayMs = 500
        onStatus(.connected)
        let queued = pendingSend
        pendingSend.removeAll()
        for s in queued {
            webSocketTask.send(.string(s)) { _ in }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }
}
