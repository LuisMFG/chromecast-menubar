import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// "Abrir com → Chromecast" no Finder
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .castFiles, object: urls)
    }
}

@main
struct CastMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = CastStore()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(store)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: store.isCasting ? "tv.fill" : "tv")
                if let m = store.media {
                    Image(systemName: m.isPlaying ? "play.fill" : "pause.fill")
                }
                if store.sleepActive {
                    Image(systemName: "moon.zzz.fill")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
