/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI

/// Height-only padding plus an overlay: lyrics never report an intrinsic width
/// to the closed notch's stack. Keep this invariant when changing rendering.
struct PinnedLyricsModifier: ViewModifier {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.pinnedLyricContext) private var context
    let isVisible: Bool

    private var tint: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
            : .gray
    }

    func body(content: Content) -> some View {
        let height = PinnedLyricsView.reservedHeight(isEligible: isVisible,
            availability: musicManager.lyricsAvailability, context: context)
        content
            .padding(.bottom, height)
            .overlay(alignment: .bottom) {
                if height > 0 {
                    if musicManager.lyricsAvailability == .timed {
                        lyricRows
                    } else if musicManager.lyricsAvailability == .loading {
                        Text("加载中")
                            .font(.system(size: PinnedLyricsView.fontSize, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: PinnedLyricsView.rowHeight * CGFloat(context.displayedRowCount))
                            .padding(.bottom, PinnedLyricsView.gap)
                    } else if musicManager.lyricsAvailability == .instrumental {
                        InstrumentalBreakNotes(fontSize: PinnedLyricsView.fontSize, weight: .medium)
                            .foregroundStyle(tint.ensureMinimumBrightness(factor: 0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: PinnedLyricsView.rowHeight * CGFloat(context.displayedRowCount))
                            .padding(.bottom, PinnedLyricsView.gap)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("纯音乐")
                    }
                }
            }
            .animation(isVisible ? .smooth(duration: 0.28) : nil, value: height)
    }

    private var lyricRows: some View {
        let displayIndex = PinnedLyricsContextRows.displayIndex(lines: musicManager.syncedLyrics, currentIndex: musicManager.currentLyricIndex)
        let slots = PinnedLyricsContextRows.slots(lines: musicManager.syncedLyrics,
            duration: musicManager.songDuration, currentIndex: musicManager.currentLyricIndex,
            context: context)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !musicManager.isPlaying)) { timeline in
            let progress = displayIndex == musicManager.currentLyricIndex ? musicManager.currentLyricSweepProgress(at: timeline.date) : 1
            let window = musicManager.lyricWindow(at: displayIndex)
            let duration = window.map { $0.end - $0.start } ?? 0
            VStack(spacing: 0) {
                ForEach(slots.indices, id: \.self) { index in
                    let slot = slots[index]
                    PinnedLyricMarquee(text: slot.text, canScroll: context == .current || slot.isCurrent, isCurrent: slot.isCurrent, progress: progress, duration: duration, tint: tint)
                        .id("\(displayIndex):\(slot.text)")
                }
            }
            .animation(.smooth(duration: 0.18), value: slots)
        }
        .padding(.horizontal, 10)
        .frame(height: PinnedLyricsView.rowHeight * CGFloat(context.displayedRowCount))
        .padding(.bottom, PinnedLyricsView.gap)
        .clipped()
    }
}

extension View {
    func pinnedLyrics(isVisible: Bool) -> some View {
        modifier(PinnedLyricsModifier(isVisible: isVisible))
    }
}

enum PinnedLyricsView {
    static let fontSize: CGFloat = 10
    static let gap: CGFloat = 4
    static let rowHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (font.ascender - font.descender + font.leading).rounded(.up) + 1
    }()

    // Availability affects the words, never the reserved space while playing.
    static func shouldReserve(lyricsEnabled: Bool, pinEnabled: Bool, surfaceEligible: Bool, availability _: LyricsAvailability) -> Bool {
        lyricsEnabled && pinEnabled && surfaceEligible
    }

    /// Loading, unavailable, untimed and instrumental tracks keep the same height.
    static func reservedHeight(isEligible: Bool, availability _: LyricsAvailability, context: PinnedLyricContext) -> CGFloat {
        isEligible ? rowHeight * CGFloat(context.displayedRowCount) + gap : 0
    }
}
