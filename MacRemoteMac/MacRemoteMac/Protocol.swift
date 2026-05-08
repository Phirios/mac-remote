import Foundation

/// Wire protocol shared between MacRemote (server) and MacRemote-iOS (client).
///
/// On the wire: each WebSocket text frame is a JSON object with a `t`
/// discriminator. Kept compact (`t`, `dx`, `dy`, `b`, `s`) to minimize bytes
/// per touch sample.

public enum MRMessage: Codable, Equatable {
    case move(dx: Int, dy: Int)
    case mouseDown(button: MouseButton, count: Int)
    case mouseUp(button: MouseButton, count: Int)
    case click(button: MouseButton, count: Int)
    case scroll(dx: Int, dy: Int)
    case key(key: String, mods: [Modifier], down: Bool)
    case combo(key: String, mods: [Modifier])
    case text(String)
    case media(key: String)
    case nowPlaying(title: String, artist: String, duration: Double, elapsed: Double, playing: Bool)
    case selectSource(player: String)
    case availableSources([String])

    public enum MouseButton: String, Codable {
        case left, right, middle
    }

    public enum Modifier: String, Codable {
        case cmd, shift, opt, ctrl
    }

    // MARK: Codable

    private enum Tag: String, Codable {
        case mv, down, up, click, scroll, key, combo, text, media, np, src, srcs
    }

    private enum Keys: String, CodingKey {
        case t, dx, dy, b, count, key, mods, down, s, title, artist, duration, elapsed, playing, player, list
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let tag = try c.decode(Tag.self, forKey: .t)
        switch tag {
        case .mv:
            self = .move(dx: try c.decodeIfPresent(Int.self, forKey: .dx) ?? 0,
                         dy: try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0)
        case .down:
            self = .mouseDown(button: try c.decodeIfPresent(MouseButton.self, forKey: .b) ?? .left,
                              count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        case .up:
            self = .mouseUp(button: try c.decodeIfPresent(MouseButton.self, forKey: .b) ?? .left,
                            count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        case .click:
            self = .click(button: try c.decodeIfPresent(MouseButton.self, forKey: .b) ?? .left,
                          count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        case .scroll:
            self = .scroll(dx: try c.decodeIfPresent(Int.self, forKey: .dx) ?? 0,
                           dy: try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0)
        case .key:
            self = .key(key: try c.decode(String.self, forKey: .key),
                        mods: try c.decodeIfPresent([Modifier].self, forKey: .mods) ?? [],
                        down: try c.decodeIfPresent(Bool.self, forKey: .down) ?? true)
        case .combo:
            self = .combo(key: try c.decode(String.self, forKey: .key),
                          mods: try c.decodeIfPresent([Modifier].self, forKey: .mods) ?? [])
        case .text:
            self = .text(try c.decode(String.self, forKey: .s))
        case .media:
            self = .media(key: try c.decode(String.self, forKey: .key))
        case .np:
            self = .nowPlaying(
                title:    try c.decodeIfPresent(String.self, forKey: .title)    ?? "",
                artist:   try c.decodeIfPresent(String.self, forKey: .artist)   ?? "",
                duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0,
                elapsed:  try c.decodeIfPresent(Double.self, forKey: .elapsed)  ?? 0,
                playing:  try c.decodeIfPresent(Bool.self,   forKey: .playing)  ?? false
            )
        case .src:
            self = .selectSource(player: try c.decode(String.self, forKey: .player))
        case .srcs:
            self = .availableSources(try c.decodeIfPresent([String].self, forKey: .list) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .move(let dx, let dy):
            try c.encode(Tag.mv, forKey: .t)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case .mouseDown(let b, let n):
            try c.encode(Tag.down, forKey: .t)
            try c.encode(b, forKey: .b); try c.encode(n, forKey: .count)
        case .mouseUp(let b, let n):
            try c.encode(Tag.up, forKey: .t)
            try c.encode(b, forKey: .b); try c.encode(n, forKey: .count)
        case .click(let b, let n):
            try c.encode(Tag.click, forKey: .t)
            try c.encode(b, forKey: .b); try c.encode(n, forKey: .count)
        case .scroll(let dx, let dy):
            try c.encode(Tag.scroll, forKey: .t)
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case .key(let k, let m, let down):
            try c.encode(Tag.key, forKey: .t)
            try c.encode(k, forKey: .key); try c.encode(m, forKey: .mods); try c.encode(down, forKey: .down)
        case .combo(let k, let m):
            try c.encode(Tag.combo, forKey: .t)
            try c.encode(k, forKey: .key); try c.encode(m, forKey: .mods)
        case .text(let s):
            try c.encode(Tag.text, forKey: .t)
            try c.encode(s, forKey: .s)
        case .media(let k):
            try c.encode(Tag.media, forKey: .t)
            try c.encode(k, forKey: .key)
        case .nowPlaying(let title, let artist, let duration, let elapsed, let playing):
            try c.encode(Tag.np, forKey: .t)
            try c.encode(title, forKey: .title); try c.encode(artist, forKey: .artist)
            try c.encode(duration, forKey: .duration); try c.encode(elapsed, forKey: .elapsed)
            try c.encode(playing, forKey: .playing)
        case .selectSource(let p):
            try c.encode(Tag.src, forKey: .t)
            try c.encode(p, forKey: .player)
        case .availableSources(let list):
            try c.encode(Tag.srcs, forKey: .t)
            try c.encode(list, forKey: .list)
        }
    }
}

public enum MRCodec {
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    public static func decode(_ data: Data) throws -> MRMessage {
        try decoder.decode(MRMessage.self, from: data)
    }
    public static func decode(_ string: String) throws -> MRMessage {
        guard let d = string.data(using: .utf8) else { throw NSError(domain: "MRCodec", code: 1) }
        return try decode(d)
    }
    public static func encodeData(_ msg: MRMessage) throws -> Data {
        try encoder.encode(msg)
    }
    public static func encodeString(_ msg: MRMessage) throws -> String {
        let d = try encodeData(msg)
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}
