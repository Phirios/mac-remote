import Foundation
import CryptoKit

/// Minimal RFC 6455 WebSocket frame encoder/decoder. Sized for our use case:
/// - we receive small text frames (one event per frame),
/// - we send only ping/pong/close (no data frames back),
/// - no continuation/fragmentation handling (any text frame must be FIN=1).

enum WSOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WSFrame {
    var fin: Bool
    var opcode: WSOpcode
    var payload: Data

    /// Parse one frame from `buffer`. Returns the frame and how many bytes
    /// were consumed, or `nil` if more data is needed.
    static func parse(_ buffer: Data) -> (frame: WSFrame, consumed: Int)? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let fin = (b0 & 0x80) != 0
        guard let opcode = WSOpcode(rawValue: b0 & 0x0F) else { return nil }
        let masked = (b1 & 0x80) != 0
        var payloadLen = Int(b1 & 0x7F)
        var idx = buffer.startIndex + 2

        if payloadLen == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLen = (Int(buffer[idx]) << 8) | Int(buffer[idx + 1])
            idx += 2
        } else if payloadLen == 127 {
            guard buffer.count >= 10 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 { len = (len << 8) | UInt64(buffer[idx + i]) }
            idx += 8
            // Cap to a sane size to avoid memory blow-ups from a malicious peer.
            guard len < 1_048_576 else { return nil }
            payloadLen = Int(len)
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= idx - buffer.startIndex + 4 else { return nil }
            maskKey = Array(buffer[idx..<idx + 4])
            idx += 4
        }

        let totalNeeded = (idx - buffer.startIndex) + payloadLen
        guard buffer.count >= totalNeeded else { return nil }

        var payload = Data(buffer[idx..<idx + payloadLen])
        if masked {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= maskKey[i % 4]
            }
        }
        return (WSFrame(fin: fin, opcode: opcode, payload: payload), totalNeeded)
    }

    /// Encode a server→client frame (no masking, per RFC 6455 §5.1).
    func encode() -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0x00) | opcode.rawValue)
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len < 65536 {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127)
            for i in (0..<8).reversed() {
                out.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func text(_ s: String) -> WSFrame {
        WSFrame(fin: true, opcode: .text, payload: Data(s.utf8))
    }
    static func close(code: UInt16 = 1000, reason: String = "") -> WSFrame {
        var p = Data()
        p.append(UInt8(code >> 8)); p.append(UInt8(code & 0xFF))
        p.append(reason.data(using: .utf8) ?? Data())
        return WSFrame(fin: true, opcode: .close, payload: p)
    }
    static func pong(_ payload: Data) -> WSFrame {
        WSFrame(fin: true, opcode: .pong, payload: payload)
    }
}

enum WSHandshake {
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Compute the value for the `Sec-WebSocket-Accept` response header.
    static func acceptKey(forClientKey key: String) -> String {
        let combined = key + magicGUID
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }

    /// Build the 101 Switching Protocols response.
    static func upgradeResponse(clientKey: String) -> Data {
        let accept = acceptKey(forClientKey: clientKey)
        let lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

/// Tiny HTTP request parser — enough for the WS upgrade handshake.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]   // lowercased keys

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        // Body is irrelevant for an upgrade — we only need headers.
        guard let headEnd = s.range(of: "\r\n\r\n") else { return nil }
        let head = s[..<headEnd.lowerBound]
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: parts[0], path: parts[1], headers: headers)
    }
}
