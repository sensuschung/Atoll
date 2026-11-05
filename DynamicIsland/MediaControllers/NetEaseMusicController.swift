import Foundation
import AppKit

/// NetEase publishes metadata through macOS Now Playing, not an AppleScript dictionary.
final class NetEaseMusicController: FilteredNowPlayingController {
    static let bundleIdentifier = "com.netease.163music"
    @MainActor private var modeState = NetEasePlaybackModeState()
    @MainActor private var isSettingMode = false

    init?() {
        super.init(bundleIdentifier: Self.bundleIdentifier, controllerName: "NetEaseMusicController")
    }

    // MediaRemote commands target the system player. Never knowingly control a
    // competing app when the user explicitly selected NetEase in settings.
    override func play() async {
        guard canControlTargetSession else { return }
        await super.play()
    }

    override func pause() async {
        guard canControlTargetSession else { return }
        await super.pause()
    }

    override func togglePlay() async {
        guard canControlTargetSession else { return }
        await super.togglePlay()
    }

    override func nextTrack() async {
        guard canControlTargetSession else { return }
        await super.nextTrack()
    }

    override func previousTrack() async {
        guard canControlTargetSession else { return }
        await super.previousTrack()
    }

    override func seek(to time: Double) async {
        guard canControlTargetSession, time.isFinite else { return }
        await super.seek(to: max(0, time))
    }

    @MainActor override var canEverFavorite: Bool { true }
    @MainActor override var supportsFavoriting: Bool { NetEaseMusicAccessibility.isAvailable }

    override func isCurrentTrackFavorited() async -> Bool? {
        guard NetEaseMusicAccessibility.isAvailable else { return nil }
        return await NetEaseMusicAccessibility.read(.favorite)
    }

    override func setCurrentTrackFavorited(_ favorited: Bool) async -> Bool {
        guard NetEaseMusicAccessibility.isAvailable else { return false }
        return await NetEaseMusicAccessibility.set(.favorite, checked: favorited)
    }

    override func toggleShuffle() async {
        await setMode(modeState.nextShuffleMode)
    }

    override func toggleRepeat() async {
        await MainActor.run {
            NetEaseRepeatMenu.present(selectedMode: modeState.lastRequestedMode) { [weak self] mode in
                Task { await self?.setMode(mode) }
            }
        }
    }

    @MainActor override func applyingLocalPlaybackMode(to state: PlaybackState) -> PlaybackState {
        modeState.applying(to: state)
    }

    @MainActor private func setMode(_ mode: NetEasePlaybackMode) async {
        // Ignore overlapping clicks while the accessibility queue is busy so
        // completion order cannot overwrite the last mode with an older one.
        guard !isSettingMode else { return }
        isSettingMode = true
        defer { isSettingMode = false }
        let accepted = await NetEaseMusicAccessibility.pressMode(mode.control)
        modeState.record(mode, accepted: accepted)
        if accepted { refreshLocalPlaybackMode() }
    }
}

/// Checkmarks refer only to the most recent command accepted from Atoll.
@MainActor
private final class NetEaseRepeatMenu: NSObject {
    private var onSelect: ((NetEasePlaybackMode) -> Void)?

    static func present(selectedMode: NetEasePlaybackMode?, onSelect: @escaping (NetEasePlaybackMode) -> Void) {
        let handler = NetEaseRepeatMenu()
        handler.onSelect = onSelect
        let menu = NSMenu(title: "网易云播放模式")
        let description = NSMenuItem(title: selectedMode == nil ? "当前模式未知，请选择播放模式" : "勾选为 Atoll 最近设置的模式", action: nil, keyEquivalent: "")
        description.isEnabled = false
        menu.addItem(description)
        for mode in NetEasePlaybackMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(handler.selectMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            item.state = selectedMode == mode ? .on : .off
            item.target = handler
            menu.addItem(item)
        }
        withExtendedLifetime(handler) { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = NetEasePlaybackMode(rawValue: sender.tag) else { return }
        onSelect?(mode)
    }
}
