import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Atalhos globais (funcionam com qualquer app em primeiro plano, sem permissão de Acessibilidade).
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    func register(keyCode: Int, modifiers: Int, _ action: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x43415354), id: id) // 'CAST'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Aviso flutuante no centro-baixo da tela, no estilo do HUD de volume do macOS.
@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(symbol: String, title: String, level: Double? = nil) {
        let view = HUDView(symbol: symbol, title: title, level: level)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - host.frame.width / 2, y: f.minY + 120,
                              width: host.frame.width, height: host.frame.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }
    }
}

private struct HUDView: View {
    let symbol: String
    let title: String
    let level: Double?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol, variableValue: level)
                .font(.system(size: 34, weight: .medium))
            Text(title).font(.system(size: 12, weight: .semibold))
            if let level {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: 140 * level)
                }
                .frame(width: 140, height: 5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.6)))
        .background(GlassBackground().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .environment(\.colorScheme, .dark)
    }
}
