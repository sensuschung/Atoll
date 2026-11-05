import XCTest
@testable import Atoll

final class NetEaseMusicAccessibilityTests: XCTestCase {
    func testFavoriteUsesActionTitleInsteadOfAbsentCheckmark() {
        XCTAssertEqual(NetEaseMusicAccessibility.favoriteState(forTitle: "喜欢歌曲"), false)
        XCTAssertEqual(NetEaseMusicAccessibility.favoriteState(forTitle: "取消喜欢"), true)
        XCTAssertEqual(NetEaseMusicAccessibility.favoriteState(forTitle: "Like"), false)
        XCTAssertEqual(NetEaseMusicAccessibility.favoriteState(forTitle: "Dislike"), true)
        XCTAssertNil(NetEaseMusicAccessibility.favoriteState(forTitle: "收藏到歌单"))
    }

    func testUnknownTitlesDoNotBecomeFalseFavoriteState() {
        XCTAssertNil(NetEaseMusicAccessibility.favoriteState(forTitle: ""))
        XCTAssertNil(NetEaseMusicAccessibility.favoriteState(forTitle: "随机播放"))
        XCTAssertEqual(NetEaseMusicAccessibility.favoriteState(forTitle: " 取消喜欢 "), true)
    }
    func testUnknownModeDoesNotTrustSystemModeFields() {
        var snapshot = PlaybackState(bundleIdentifier: NetEaseMusicController.bundleIdentifier)
        snapshot.isShuffled = true
        snapshot.repeatMode = .all
        let result = NetEasePlaybackModeState().applying(to: snapshot)
        XCTAssertEqual(result.isShuffled, false)
        XCTAssertEqual(result.repeatMode, .off)
    }

    func testModeSurvivesTrackRefreshAndKeepsModesExclusive() {
        var modes = NetEasePlaybackModeState()
        for mode in NetEasePlaybackMode.allCases {
            modes.record(mode, accepted: true)
            var snapshot = PlaybackState(bundleIdentifier: NetEaseMusicController.bundleIdentifier)
            snapshot.title = "New track"
            snapshot.currentTime = 42
            snapshot.isShuffled = true
            snapshot.repeatMode = .all
            let result = modes.applying(to: snapshot)
            XCTAssertEqual(result.title, "New track")
            XCTAssertEqual(result.currentTime, 42)
            XCTAssertEqual(result.isShuffled, mode == .shuffle)
            XCTAssertEqual(result.repeatMode, mode == .repeatOne ? .one : mode == .repeatAll ? .all : .off)
        }
    }

    func testFailedCommandPreservesSelectionAndShuffleRestoresPreviousMode() {
        var modes = NetEasePlaybackModeState()
        modes.record(.repeatOne, accepted: false)
        XCTAssertNil(modes.lastRequestedMode)
        XCTAssertEqual(modes.nextShuffleMode, .shuffle)
        modes.record(.shuffle, accepted: true)
        XCTAssertEqual(modes.nextShuffleMode, .order)
        modes.record(.repeatAll, accepted: true)
        modes.record(.shuffle, accepted: true)
        modes.record(.repeatOne, accepted: false)
        XCTAssertEqual(modes.lastRequestedMode, .shuffle)
        XCTAssertEqual(modes.nextShuffleMode, .repeatAll)
        modes.record(modes.nextShuffleMode, accepted: true)
        XCTAssertEqual(modes.lastRequestedMode, .repeatAll)
        XCTAssertEqual(modes.nextShuffleMode, .shuffle)
    }

}
