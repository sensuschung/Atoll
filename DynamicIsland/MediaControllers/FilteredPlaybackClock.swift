import Foundation

/// Position and sample time must travel together, including across pauses.
enum FilteredPlaybackClock {
    static func applying(payload: NowPlayingPayload, diff: Bool, previous: PlaybackState, state: PlaybackState, now: Date) -> PlaybackState {
        var result = state
        let sampleTime = payload.resolvedTimestamp
        if let elapsed = payload.resolvedElapsedTime {
            result.currentTime = elapsed
            result.lastUpdated = sampleTime ?? now
        } else if payload.clearsElapsedTime || !diff {
            result.currentTime = 0
            result.lastUpdated = sampleTime ?? now
        } else {
            result.currentTime = previous.currentTime
            result.lastUpdated = previous.lastUpdated
        }

        let sameTrack = previous.bundleIdentifier == state.bundleIdentifier && previous.title == state.title && previous.artist == state.artist && previous.album == state.album
        let currentSample = payload.resolvedElapsedTime != nil && (sampleTime.map { abs(now.timeIntervalSince($0)) <= 2 } ?? true)
        let transition = previous.isPlaying != state.isPlaying || previous.playbackRate != state.playbackRate
        if sameTrack && transition && !currentSample && !payload.clearsElapsedTime {
            let elapsed = previous.isPlaying ? max(0, now.timeIntervalSince(previous.lastUpdated)) * previous.playbackRate : 0
            result.currentTime = max(0, previous.currentTime + elapsed)
            result.lastUpdated = now
        } else if sameTrack && !currentSample && payload.resolvedElapsedTime != nil && result.lastUpdated < previous.lastUpdated {
            // A repeated pre-pause sample must not undo a locally frozen anchor.
            result.currentTime = previous.currentTime
            result.lastUpdated = previous.lastUpdated
        }
        return result
    }
}
