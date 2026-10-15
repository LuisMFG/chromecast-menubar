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
        if ProcessInfo.processInfo.environment["CHECK_STRINGS"] != nil {
            // chaves com variáveis: confere se a tradução é encontrada
            print(String(localized: "Convertendo \(42)%"), "|", String(localized: "O Chromecast recusou \("reboot") (\(400))"),
                  "|", String(localized: "O yt-dlp não conseguiu ler este site: \("x".prefix(1)). Às vezes resolve atualizando: brew upgrade yt-dlp"),
                  "|", String(localized: "YouTube respondeu HTTP \(500)"), "|", String(localized: "Tocando no \("YouTube")"))
            exit(0)
        }
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
            RecentCast(url: "https://youtu.be/abcdefghijk", title: "Lofi hip hop radio — beats to relax/study to", kind: "youtube", image: nil, date: now.addingTimeInterval(-3600)),
            RecentCast(url: "https://open.spotify.com/album/1", title: "Random Access Memories", kind: "media", image: nil, date: now.addingTimeInterval(-7200)),
            RecentCast(url: "https://www.instagram.com/reel/abc/", title: "@natgeo reel", kind: "media", image: nil, date: now.addingTimeInterval(-86400)),
            RecentCast(url: "https://x.com/nasa/status/1", title: "NASA — live launch", kind: "media", image: nil, date: now.addingTimeInterval(-3 * 86400)),
        ]
        let playing = CastStore(preview: yt, media: media, volume: 0.65,
                                tint: Color(hue: 0.08, saturation: 0.6, brightness: 0.95), tab: tab)
        write(RootView().environmentObject(playing), "\(out)/playing.png")
        let xtab = BrowserTab(browser: "Brave", bundleId: "com.brave.Browser", title: "NASA on X: \"Artemis launch\"",
                              url: URL(string: "https://x.com/nasa/status/1")!)
        write(RootView().environmentObject(CastStore(preview: backdrop, media: nil, volume: 0.8, tab: xtab, recents: recents)), "\(out)/idle.png")
        let spotify = CastStore(preview: backdrop, media: nil, volume: 0.8, tab: nil, recents: [])
        spotify.notice = "Abri no Spotify. Lá, toque em “Conectar a um dispositivo” e escolha Sala — o Spotify só transmite pelo próprio app."
        write(RootView().environmentObject(spotify), "\(out)/notice.png")
    }
}
