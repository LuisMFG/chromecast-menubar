import AppKit
import SwiftUI

/// Quando ligado, efeitos que não aparecem em captura offscreen (vidro) viram equivalentes estáticos.
enum SnapshotMode {
    @MainActor static var isOn = false
}

struct Glass: View {
    var body: some View {
        if SnapshotMode.isOn {
            Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.92)
        } else {
            GlassBackground()
        }
    }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

enum Haptics {
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func edge() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

/// TV desenhada para o estado "nada transmitindo": tela com gradiente que respira devagar.
struct IdleTV: View {
    let tint: Color

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12)))
                TimelineView(.animation(minimumInterval: 1 / 30, paused: SnapshotMode.isOn)) { ctx in
                    let t = SnapshotMode.isOn ? 1.2 : ctx.date.timeIntervalSinceReferenceDate
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.55), Color(red: 0.95, green: 0.55, blue: 0.4).opacity(0.35), tint.opacity(0.2)],
                                             startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t * 0.3), y: 0),
                                             endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t * 0.3), y: 1)))
                        .padding(6)
                }
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 176, height: 104)
            Capsule().fill(Color(white: 0.25)).frame(width: 48, height: 4).padding(.top, 6)
        }
    }
}
