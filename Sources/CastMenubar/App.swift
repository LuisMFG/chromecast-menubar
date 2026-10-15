import SwiftUI

@main
struct CastMenubarApp: App {
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
