import Foundation

/// Reads now-playing info and controls playback position via the private
/// MediaRemote.framework (loaded at runtime — no link dependency).
final class NowPlayingMonitor {
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private let getInfoFn: GetInfoFn?
    private let setElapsedFn: SetElapsedFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        getInfoFn   = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo").map   { unsafeBitCast($0, to: GetInfoFn.self) }
        setElapsedFn = dlsym(handle, "MRMediaRemoteSetElapsedTime").map { unsafeBitCast($0, to: SetElapsedFn.self) }
    }

    struct TrackInfo {
        var title: String
        var artist: String
        var duration: Double
        var elapsed: Double
        var playing: Bool
    }

    func getInfo(completion: @escaping (TrackInfo?) -> Void) {
        guard let fn = getInfoFn else { completion(nil); return }
        fn(.main) { dict in
            guard let dict else { completion(nil); return }
            let title    = dict["Title"]        as? String ?? ""
            let artist   = dict["Artist"]       as? String ?? ""
            let duration = dict["Duration"]     as? Double ?? 0
            let elapsed  = dict["ElapsedTime"]  as? Double ?? 0
            let rate     = dict["PlaybackRate"] as? Double ?? 0
            completion(TrackInfo(title: title, artist: artist,
                                 duration: duration, elapsed: elapsed,
                                 playing: rate > 0))
        }
    }

    func seekByOffset(_ offset: Double) {
        guard let setFn = setElapsedFn else { return }
        getInfo { info in
            guard let info, info.duration > 0 else { return }
            let newTime = max(0, min(info.duration, info.elapsed + offset))
            setFn(newTime)
        }
    }
}
