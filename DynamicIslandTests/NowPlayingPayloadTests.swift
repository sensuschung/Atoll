/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import Atoll

/// The adapter's diff updates omit what has not changed, so "absent" and
/// "present but null" mean different things for the playback position. Optional
/// decoding renders both as nil, so the distinction is pinned here.
final class NowPlayingPayloadTests: XCTestCase {

    private func decode(_ json: String) throws -> NowPlayingPayload {
        try JSONDecoder().decode(NowPlayingPayload.self, from: Data(json.utf8))
    }

    func testAnOmittedPositionIsNotTreatedAsCleared() throws {
        let payload = try decode(#"{"title":"a"}"#)

        XCTAssertNil(payload.resolvedElapsedTime)
        XCTAssertFalse(payload.clearsElapsedTime)
    }

    func testANullPositionIsTreatedAsCleared() throws {
        let payload = try decode(#"{"elapsedTime":null}"#)

        XCTAssertNil(payload.resolvedElapsedTime)
        XCTAssertTrue(payload.clearsElapsedTime)
    }

    func testANullMicrosecondPositionIsTreatedAsCleared() throws {
        let payload = try decode(#"{"elapsedTimeMicros":null}"#)

        XCTAssertTrue(payload.clearsElapsedTime)
    }

    func testAPositionThatIsActuallyPresentIsNotCleared() throws {
        let payload = try decode(#"{"elapsedTime":12.5}"#)

        XCTAssertEqual(payload.resolvedElapsedTime ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertFalse(payload.clearsElapsedTime)
    }

    func testMicrosecondValuesWinOverTheSecondsForms() throws {
        let payload = try decode(#"{"elapsedTime":9,"elapsedTimeMicros":9720000,"duration":100,"durationMicros":379226000}"#)

        XCTAssertEqual(payload.resolvedElapsedTime ?? 0, 9.72, accuracy: 0.0001)
        XCTAssertEqual(payload.resolvedDuration ?? 0, 379.226, accuracy: 0.0001)
    }

    func testTheMicrosecondAnchorKeepsItsSubSecondPart() throws {
        // The string form is formatted to whole seconds, so preferring it would
        // put the anchor up to a second early and bias playback estimates ahead.
        let payload = try decode(
            #"{"timestamp":"2026-08-21T14:00:13Z","timestampEpochMicros":1787320813448212}"#
        )

        XCTAssertEqual(
            payload.resolvedTimestamp?.timeIntervalSince1970 ?? 0,
            1787320813.448212,
            accuracy: 0.0001
        )
    }

    func testTheStringAnchorIsUsedWhenTheAdapterIgnoresMicros() throws {
        let payload = try decode(#"{"timestamp":"2026-08-21T14:00:13Z"}"#)

        XCTAssertEqual(
            payload.resolvedTimestamp?.timeIntervalSince1970 ?? 0,
            1787320813,
            accuracy: 0.0001
        )
    }

    func testSpotifyAdvertisementURIIsRecognized() {
        var state = PlaybackState(bundleIdentifier: SpotifyController.bundleIdentifier)
        state.contentIdentifier = "spotify:ad:campaign-123"
        state.title = "Sponsored message"
        state.duration = 30

        XCTAssertTrue(MusicManager.isLikelyAdvertisement(state))
    }

    func testRegularShortSpotifyTrackIsNotRecognizedAsAdvertisement() {
        var state = PlaybackState(bundleIdentifier: SpotifyController.bundleIdentifier)
        state.contentIdentifier = "spotify:track:123"
        state.title = "Short song"
        state.artist = "Artist"
        state.album = "Album"
        state.duration = 45

        XCTAssertFalse(MusicManager.isLikelyAdvertisement(state))
    }

    func testAdvertisementHeuristicDoesNotApplyToOtherSources() {
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.contentIdentifier = "spotify:ad:campaign-123"
        state.title = "Sponsored message"
        state.duration = 30

        XCTAssertFalse(MusicManager.isLikelyAdvertisement(state))
    }
}

final class FilteredPlaybackClockTests: XCTestCase {
    private func update(_ json: String, previous: PlaybackState, playing: Bool, now: Double, title: String = "Track") throws -> PlaybackState {
        let payload = try JSONDecoder().decode(NowPlayingPayload.self, from: Data(json.utf8))
        var state = previous
        state.title = title
        state.isPlaying = playing
        state.playbackRate = playing ? 1 : 0
        return FilteredPlaybackClock.applying(payload: payload, diff: true, previous: previous, state: state, now: Date(timeIntervalSince1970: now))
    }

    private var initial: PlaybackState {
        var state = PlaybackState(bundleIdentifier: "test")
        state.title = "Track"
        state.currentTime = 10
        state.lastUpdated = Date(timeIntervalSince1970: 100)
        state.isPlaying = true
        return state
    }

    func testFreshPositionWithoutTimestampDoesNotReuseOldAnchor() throws {
        let state = try update(#"{"elapsedTime":15}"#, previous: initial, playing: true, now: 105)
        XCTAssertEqual(state.currentTime, 15)
        XCTAssertEqual(state.lastUpdated.timeIntervalSince1970, 105)
    }

    func testTimestampOnlyDiffKeepsOriginalPair() throws {
        let state = try update(#"{"timestampEpochMicros":105000000}"#, previous: initial, playing: true, now: 105)
        XCTAssertEqual(state.currentTime, 10)
        XCTAssertEqual(state.lastUpdated.timeIntervalSince1970, 100)
    }

    func testPauseAndResumeDoNotCountPausedSeconds() throws {
        let stale = #"{"elapsedTime":10,"timestampEpochMicros":100000000}"#
        let paused = try update(stale, previous: initial, playing: false, now: 105)
        XCTAssertEqual(paused.currentTime, 15)
        let repeated = try update(stale, previous: paused, playing: false, now: 108)
        XCTAssertEqual(repeated.currentTime, 15)
        let resumed = try update(stale, previous: repeated, playing: true, now: 110)
        XCTAssertEqual(resumed.currentTime, 15)
        XCTAssertEqual(resumed.lastUpdated.timeIntervalSince1970, 110)
    }

    func testFreshSeekAndTrackChangeOverrideOldPosition() throws {
        let seek = try update(#"{"elapsedTimeMicros":2500000,"timestampEpochMicros":105123456}"#, previous: initial, playing: false, now: 105.2)
        XCTAssertEqual(seek.currentTime, 2.5)
        XCTAssertEqual(seek.lastUpdated.timeIntervalSince1970, 105.123456, accuracy: 0.000001)
        let changed = try update(#"{"elapsedTime":0,"timestampEpochMicros":100000000}"#, previous: initial, playing: false, now: 110, title: "Other")
        XCTAssertEqual(changed.currentTime, 0)
        let cleared = try update(#"{"elapsedTime":null}"#, previous: initial, playing: false, now: 110)
        XCTAssertEqual(cleared.currentTime, 0)
    }
}
