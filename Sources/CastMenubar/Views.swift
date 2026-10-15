import SwiftUI

private let defaultTint = Color(red: 0.55, green: 0.55, blue: 1.0)

// MARK: - Raiz

struct RootView: View {
    @EnvironmentObject var store: CastStore

    private var tint: Color { store.artworkTint ?? defaultTint }

    var body: some View {
        VStack(spacing: 16) {
            Header()
            if !store.connected {
                Searching()
            } else if let media = store.media {
                NowPlaying(media: media, appName: store.app?.name ?? "", tint: tint)
            } else if let app = store.app, !app.isIdle {
                AppOnly(app: app, tint: tint)
            } else {
                Idle(tint: tint)
            }
            if store.connected {
                VolumeRow(tint: tint)
            }
            Footer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 312)
        .background {
            ZStack {
                Glass()
                Color.black.opacity(0.45)
                RadialGradient(colors: [tint.opacity(store.isCasting ? 0.32 : 0.12), .clear],
                               center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 300)
            }
            .animation(.easeInOut(duration: 0.6), value: store.artworkTint)
        }
        .environment(\.colorScheme, .dark)
        .tint(tint)
        .task { store.requestStatus() }
    }
}

// MARK: - Cabeçalho

private struct Header: View {
    @EnvironmentObject var store: CastStore

    private var status: String {
        guard store.connected else { return String(localized: "Desconectado") }
        guard let app = store.app else { return String(localized: "Pronto para transmitir") }
        if app.isIdle { return String(localized: "Tela de fundo") }
        if let m = store.media {
            return m.isPlaying ? String(localized: "Tocando no \(app.name)") : String(localized: "Pausado no \(app.name)")
        }
        return String(localized: "Transmitindo \(app.name)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                if store.devices.count > 1 {
                    Menu(store.displayName) {
                        ForEach(store.devices) { d in Button(d.name) { store.selectedId = d.id } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(store.displayName).font(.system(size: 15, weight: .semibold))
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.connected ? (store.isCasting ? Color.accentColor : .green) : .orange)
                        .frame(width: 6, height: 6)
                    Text(status).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isCasting {
                Button(action: store.stopCasting) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Parar transmissão"))
            }
        }
    }
}

// MARK: - Tocando agora

private struct NowPlaying: View {
    @EnvironmentObject var store: CastStore
    let media: MediaState
    let appName: String
    let tint: Color

    var body: some View {
        VStack(spacing: 14) {
            Artwork(url: media.artwork, tint: tint)

            VStack(spacing: 3) {
                Text(media.title ?? appName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let sub = media.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            if media.duration != nil, media.canSeek {
                Scrubber(media: media, tint: tint)
            }

            HStack(spacing: 28) {
                RoundIcon(symbol: "gobackward.10", size: 40) { store.skip(-10) }
                    .disabled(!media.canSeek)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button(action: store.togglePlay) {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.black)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(tint.gradient))
                        .shadow(color: tint.opacity(0.5), radius: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!media.canPause)
                .keyboardShortcut(.space, modifiers: [])
                RoundIcon(symbol: "goforward.30", size: 40) { store.skip(30) }
                    .disabled(!media.canSeek)
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
    }
}

private struct Artwork: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "play.tv").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.6)))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
            }
        }
        .frame(width: 280, height: 158)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1)))
        .shadow(color: tint.opacity(0.35), radius: 18, y: 8)
    }
}

private struct Scrubber: View {
    @EnvironmentObject var store: CastStore
    let media: MediaState
    let tint: Color
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = max(media.duration ?? 1, 1)
            let pos = dragging ?? media.position(at: ctx.date)
            VStack(spacing: 5) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(tint).frame(width: max(0, w * pos / duration))
                        Circle().fill(.white)
                            .frame(width: 12, height: 12)
                            .offset(x: w * pos / duration - 6)
                            .opacity(hovering || dragging != nil ? 1 : 0)
                    }
                    .frame(height: hovering || dragging != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in dragging = min(max(g.location.x / w, 0), 1) * duration }
                        .onEnded { _ in if let d = dragging { store.seek(to: d) }; dragging = nil })
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.15), value: hovering)

                HStack {
                    Text(format(pos))
                    Spacer()
                    Text("-" + format(duration - pos))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ t: Double) -> String {
        let s = max(Int(t.rounded()), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Outros estados

private struct AppOnly: View {
    let app: ReceiverApp
    let tint: Color
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 280, height: 120)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.12)))
            Text(app.name).font(.system(size: 15, weight: .semibold))
            Text(app.statusText.isEmpty ? String(localized: "Este app não expõe controles de mídia.") : app.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct Idle: View {
    let tint: Color
    var body: some View {
        VStack(spacing: 10) {
            IdleTV(tint: tint)
            Text("Nada transmitindo").font(.system(size: 14, weight: .semibold))
            Text("Transmita do celular ou do Chrome e controle por aqui.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

private struct Searching: View {
    @EnvironmentObject var store: CastStore
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.devices.isEmpty ? String(localized: "Procurando Chromecast na rede…") : String(localized: "Conectando…"))
                .font(.system(size: 12, weight: .medium))
            if store.devices.isEmpty {
                Text("Se nada aparecer, permita o acesso à Rede Local em Ajustes do Sistema → Privacidade e Segurança.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

// MARK: - Volume

private struct VolumeRow: View {
    @EnvironmentObject var store: CastStore
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Button(action: store.toggleMute) {
                Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: store.volume)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .help(store.muted ? String(localized: "Ativar som") : String(localized: "Silenciar"))

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(store.muted ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(tint))
                        .frame(width: max(8, w * store.volume))
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    change(to: g.location.x / w)
                })
            }
            .frame(height: 20)

            Text("\(Int((store.volume * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            // atalhos de teclado ↑/↓
            Group {
                Button("") { change(to: store.volume + store.volumeStep) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { change(to: store.volume - store.volumeStep) }.keyboardShortcut(.downArrow, modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.05)))
    }

    /// Um "clique" no trackpad a cada passo de volume do aparelho.
    private func change(to level: Double) {
        let step = store.volumeStep
        let new = (min(max(level, 0), 1) / step).rounded() * step
        guard abs(new - store.volume) > step / 2 else { return }
        (new <= 0 || new >= 1) ? Haptics.edge() : Haptics.tick()
        if store.muted { store.toggleMute() }
        store.setVolume(new)
    }
}

// MARK: - Rodapé

private struct Footer: View {
    @EnvironmentObject var store: CastStore
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmReboot = false

    var body: some View {
        HStack(spacing: 6) {
            if let err = store.error, !store.connected {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).lineLimit(1).truncationMode(.tail)
            } else if let info = store.info {
                if let s = info.signal {
                    Image(systemName: "wifi", variableValue: signalStrength(s))
                        .help(info.ssid.map { "\($0) · \(s) dBm" } ?? "\(s) dBm")
                }
                Text(info.firmware.isEmpty ? "Chromecast" : "Cast \(info.firmware)").lineLimit(1)
            } else if let d = store.device {
                Text(d.model)
            }
            Spacer()
            Button(action: { store.requestStatus(); store.requestDeviceInfo() }) {
                Image(systemName: "arrow.clockwise").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .keyboardShortcut("r")
            Menu {
                if store.isCasting { Button("Parar transmissão") { store.stopCasting() } }
                Button("Renomear…") { newName = store.displayName; renaming = true }
                Button("Reiniciar Chromecast…") { confirmReboot = true }
                Button("Reconectar") { store.connect() }
                Divider()
                Button("Fechar app") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!store.connected)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .alert("Renomear Chromecast", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { store.rename(to: newName) }
        } message: {
            Text("O novo nome aparece no celular, no Chrome e aqui.")
        }
        .confirmationDialog("Reiniciar o Chromecast?", isPresented: $confirmReboot) {
            Button("Reiniciar", role: .destructive) { store.reboot() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A transmissão atual é interrompida e o aparelho volta em cerca de 1 minuto.")
        }
    }

    /// -40 dBm ou melhor = cheio; -85 dBm ou pior = vazio
    private func signalStrength(_ dbm: Int) -> Double {
        min(max(Double(dbm + 85) / 45, 0.05), 1)
    }
}

private struct RoundIcon: View {
    let symbol: String
    var size: CGFloat = 36
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
