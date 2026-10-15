import AppKit
import SwiftUI

// Renderiza o painel com dados fictícios (não fala com o Chromecast).
@MainActor func write<V: View>(_ view: V, _ path: String) {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print(path)
}

@main enum Snapshot {
    @MainActor static func main() {
        let out = CommandLine.arguments.dropFirst().first ?? "docs"
        _ = NSApplication.shared
        SnapshotMode.isOn = true
        let yt = ReceiverApp(appId: "233637DE", name: "YouTube", statusText: "", isIdle: false, sessionId: "s", transportId: "t", hasMedia: true)
        let media = MediaState(sessionId: 1, playerState: "PLAYING", currentTime: 754, updatedAt: Date(), rate: 1, duration: 1932,
                               title: "Lofi hip hop radio — beats to relax/study to", subtitle: "Lofi Girl",
                               artwork: nil, canSeek: true, canPause: true)
        let backdrop = ReceiverApp(appId: "E8C28D3C", name: "Backdrop", statusText: "", isIdle: true, sessionId: "b", transportId: "b", hasMedia: false)
        let tab = BrowserTab(browser: "Brave", bundleId: "com.brave.Browser",
                             title: "Tiny Desk Concert — NPR Music", url: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!)
        let now = Date()
        let recents = [
            RecentCast(url: "https://youtu.be/a", title: "Lofi hip hop radio — beats to relax/study to", kind: "youtube", image: nil, date: now.addingTimeInterval(-3600)),
            RecentCast(url: "file:///f.mp4", title: "Férias 2025", kind: "file", image: nil, date: now.addingTimeInterval(-86400)),
            RecentCast(url: "https://vimeo.com/1", title: "The Mountain — timelapse", kind: "media", image: nil, date: now.addingTimeInterval(-3 * 86400)),
        ]
        let playing = CastStore(preview: yt, media: media, volume: 0.65,
                                tint: Color(hue: 0.08, saturation: 0.6, brightness: 0.95), tab: tab)
        write(RootView().environmentObject(playing), "\(out)/playing.png")
        write(RootView().environmentObject(CastStore(preview: backdrop, media: nil, volume: 0.8, tab: tab, recents: recents)), "\(out)/idle.png")
        let spotify = CastStore(preview: backdrop, media: nil, volume: 0.8, tab: nil, recents: [])
        spotify.notice = "Abri no Spotify. Lá, toque em “Conectar a um dispositivo” e escolha Sala — o Spotify só transmite pelo próprio app."
        write(RootView().environmentObject(spotify), "\(out)/notice.png")
    }
}
