import Foundation

/// NetEase has one mutually exclusive mode. These are commands remembered by
/// Atoll, not verified state read back from NetEase.
enum NetEasePlaybackMode: Int, CaseIterable {
    case order, repeatOne, repeatAll, shuffle

    var title: String {
        switch self {
        case .order: return "顺序播放（关闭循环）"
        case .repeatOne: return "单曲循环"
        case .repeatAll: return "列表循环"
        case .shuffle: return "随机播放"
        }
    }

    var control: NetEaseMusicAccessibility.Control {
        switch self {
        case .order: return .repeatOff
        case .repeatOne: return .repeatOne
        case .repeatAll: return .repeatAll
        case .shuffle: return .shuffle
        }
    }
}

struct NetEasePlaybackModeState {
    private(set) var lastRequestedMode: NetEasePlaybackMode?
    private var previousNonShuffleMode: NetEasePlaybackMode = .order

    var nextShuffleMode: NetEasePlaybackMode { lastRequestedMode == .shuffle ? previousNonShuffleMode : .shuffle }

    mutating func record(_ mode: NetEasePlaybackMode, accepted: Bool) {
        guard accepted else { return }
        lastRequestedMode = mode
        if mode != .shuffle { previousNonShuffleMode = mode }
    }

    func applying(to state: PlaybackState) -> PlaybackState {
        var result = state
        // An unknown initial mode stays unhighlighted; never infer it from
        // NetEase's missing/unreliable MediaRemote mode fields.
        result.isShuffled = lastRequestedMode == .shuffle
        switch lastRequestedMode {
        case .repeatOne: result.repeatMode = .one
        case .repeatAll: result.repeatMode = .all
        default: result.repeatMode = .off
        }
        return result
    }
}
