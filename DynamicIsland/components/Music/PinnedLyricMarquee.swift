import SwiftUI

/// One pass through a long line, timed against playback rather than wall time.
/// Pausing and seeking therefore use the same clock as the lyric highlight.
enum PinnedLyricScroll {
    static let initialPause: TimeInterval = 0.8
    static let endPause: TimeInterval = 0.8
    static let maximumSpeed: Double = 40
    static let minimumSpeed: Double = 12

    static func offset(overflow: CGFloat, elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard overflow.isFinite, overflow > 0, elapsed.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let travelTime = max(0.1, duration - initialPause - endPause)
        let speed = min(maximumSpeed, max(minimumSpeed, Double(overflow) / travelTime))
        return -min(overflow, CGFloat(max(0, elapsed - initialPause) * speed))
    }
}

struct PinnedLyricMarquee: View {
    let text: String
    let canScroll: Bool
    let isCurrent: Bool
    let progress: Double
    let duration: TimeInterval
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let overflow = max(0, textWidth - geometry.size.width)
            let scrolling = canScroll && !reduceMotion && overflow > 0 && duration > 0
            Group {
                if scrolling {
                    lyricText
                        .fixedSize(horizontal: true, vertical: false)
                        .lyricSweep(progress: progress, isCurrent: isCurrent, sung: .white, unsung: tint.opacity(0.55), idle: .white.opacity(0.45))
                        .offset(x: PinnedLyricScroll.offset(overflow: overflow, elapsed: progress * duration, duration: duration))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                } else {
                    lyricText
                        .truncationMode(.tail)
                        .lyricSweep(progress: progress, isCurrent: isCurrent, sung: .white, unsung: tint.opacity(0.55), idle: .white.opacity(0.45))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                }
            }
            // Measure without letting the full text widen the closed notch.
            .background {
                lyricText
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .hidden()
                    .accessibilityHidden(true)
            }
            .clipped()
        }
        .frame(height: PinnedLyricsView.rowHeight)
        // A new line must reset immediately, not animate backwards from the old offset.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var lyricText: some View {
        Text(text)
            .font(.system(size: PinnedLyricsView.fontSize, weight: .medium))
            .lineLimit(1)
    }
}
