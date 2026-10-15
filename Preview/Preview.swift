import AppKit
import SwiftUI

/// Abre o painel numa janela comum (com o aparelho real), pra inspecionar sem clicar na barra de menus.
@main enum Preview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let store = CastStore()
        let host = NSHostingView(rootView: RootView().environmentObject(store))
        let win = NSWindow(contentRect: NSRect(x: 240, y: 200, width: 312, height: 520),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.title = "Cast Preview"
        win.contentView = host
        win.isOpaque = false
        win.backgroundColor = .clear
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // PREVIEW_PNG=arquivo.png → salva o painel depois de conectar e fecha
        if let out = ProcessInfo.processInfo.environment["PREVIEW_PNG"] {
            SnapshotMode.isOn = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
        app.run()
    }
}
