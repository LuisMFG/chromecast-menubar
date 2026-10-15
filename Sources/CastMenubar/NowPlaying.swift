import AppKit
import MediaPlayer

/// Publica o que está tocando na TV no "Tocando Agora" do macOS e recebe as teclas de mídia.
/// Só ocupa as teclas enquanto há mídia na TV; quando para, devolve pro Mac.
@MainActor
final class NowPlayingBridge {
    private weak var store: CastStore?
    private var registered = false
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(store: CastStore) {
        self.store = store
    }

    func update() {
        guard let store else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let m = store.media else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        registerCommands()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: m.title ?? store.app?.name ?? "Chromecast",
            MPMediaItemPropertyArtist: m.subtitle ?? store.app?.name ?? "",
            MPMediaItemPropertyAlbumTitle: store.displayName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: m.position(at: Date()),
            MPNowPlayingInfoPropertyPlaybackRate: m.isPlaying ? m.rate : 0,
        ]
        if let d = m.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        if m.artwork != artworkURL { artworkURL = m.artwork; artwork = nil }
        if let image = store.artworkImage, artwork == nil {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = m.isPlaying ? .playing : .paused
    }

    private func registerCommands() {
        guard !registered else { return }
        registered = true
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.store?.togglePlay(); return .success }
        c.playCommand.addTarget { [weak self] _ in
            if self?.store?.media?.isPlaying == false { self?.store?.togglePlay() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            if self?.store?.media?.isPlaying == true { self?.store?.togglePlay() }
            return .success
        }
        // ⏭/⏮ do teclado viram +30 s / −10 s
        c.nextTrackCommand.addTarget { [weak self] _ in self?.store?.skip(30); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.store?.skip(-10); return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.store?.skip(30); return .success }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.store?.skip(-10); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.store?.seek(to: e.positionTime)
            return .success
        }
    }
}
