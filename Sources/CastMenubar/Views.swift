import SwiftUI
import UniformTypeIdentifiers

private let defaultTint = Color(red: 0.55, green: 0.55, blue: 1.0)

// MARK: - Raiz

struct RootView: View {
    @EnvironmentObject var store: CastStore
    @State private var dropTargeted = false

    private var tint: Color { store.artworkTint ?? defaultTint }

    var body: some View {
        VStack(spacing: 16) {
            Header()
            if let p = store.castProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(p).font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.15)))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !store.connected {
                Searching()
            } else if store.dashboardOn {
                DashboardActive(tint: tint)
            } else if let media = store.media {
                NowPlaying(media: media, appName: store.app?.name ?? "", tint: tint)
            } else if let app = store.app, !app.isIdle {
                AppOnly(app: app, tint: tint)
            } else {
                Idle(tint: tint)
            }
            if store.connected {
                VolumeRow(tint: tint)
                if store.isCasting, !store.dashboardOn { SleepRow(tint: tint) }
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
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55)))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "tv.and.mediabox").font(.system(size: 30, weight: .light))
                            Text("Solte para tocar na TV").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(tint)
                    }
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted, perform: handleDrop)
        .animation(.snappy, value: dropTargeted)
        .animation(.snappy, value: store.castProgress)
        .environment(\.colorScheme, .dark)
        .tint(tint)
        .task { store.requestStatus() }
    }
}

extension RootView {
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in await store.cast(url) }
            }
            return true
        }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in await store.cast(url) }
        }
        return true
    }
}

// MARK: - Cabeçalho

private struct Header: View {
    @EnvironmentObject var store: CastStore

    private var status: String {
        guard store.connected else { return String(localized: "Desconectado") }
        if store.dashboardOn { return String(localized: "Mostrando o painel da casa") }
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
    @EnvironmentObject var store: CastStore
    let tint: Color
    var body: some View {
        VStack(spacing: 10) {
            IdleTV(tint: tint)
            Text("Nada transmitindo").font(.system(size: 14, weight: .semibold))
            Text("Transmita do celular ou do Chrome, ou solte um arquivo aqui.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ActionButton(symbol: "rectangle.3.group", title: String(localized: "Painel da casa"), tint: tint,
                             action: store.startDashboard)
                ActionButton(symbol: "power", title: String(localized: "Ligar TV"), tint: tint,
                             action: store.turnOnTV)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}

private struct ActionButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardActive: View {
    @EnvironmentObject var store: CastStore
    let tint: Color
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05))
                if let img = store.dashboardPreview {
                    Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1)))
            .shadow(color: tint.opacity(0.3), radius: 16, y: 8)
            Text("Painel da casa na TV").font(.system(size: 14, weight: .semibold))
            Text("Relógio e clima · atualiza a cada minuto")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ActionButton(symbol: "xmark", title: String(localized: "Desligar painel"), tint: tint,
                         action: store.stopDashboard)
                .padding(.top, 4)
        }
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

// MARK: - Timer de sono

private struct SleepRow: View {
    @EnvironmentObject var store: CastStore
    let tint: Color

    var body: some View {
        Group {
            if let at = store.sleepAt {
                active(at).transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                picker.transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.05)))
        .animation(.snappy, value: store.sleepAt == nil)
    }

    private var picker: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text("Dormir em")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 2)
            ForEach([(15, "15m"), (30, "30m"), (60, "1h")], id: \.0) { m, label in
                chip(label) { store.startSleep(minutes: m) }
            }
            if store.media?.duration != nil {
                chip(String(localized: "Fim"), width: 36) { store.sleepAtEndOfEpisode() }
                    .help(String(localized: "Parar quando o episódio acabar"))
            }
        }
    }

    private func chip(_ label: String, width: CGFloat = 32, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: width, height: 24)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func active(_ at: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: 1 - store.sleepProgress(at: ctx.date))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "moon.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: store.fading)
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(remaining(at.timeIntervalSince(ctx.date)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(store.fading ? String(localized: "Abaixando o volume…")
                         : store.sleepMode == .endOfEpisode ? String(localized: "No fim do episódio")
                         : String(localized: "Para às \(at.formatted(date: .omitted, time: .shortened))"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.extendSleep(minutes: 15) } label: {
                    Text("+15m")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Button(action: store.cancelSleep) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Cancelar timer"))
            }
        }
    }

    private func remaining(_ t: TimeInterval) -> String {
        let s = max(Int(t.rounded(.up)), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Rodapé

private struct Footer: View {
    @EnvironmentObject var store: CastStore
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmReboot = false
    @State private var askingLink = false
    @State private var link = ""

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
                Button("Transmitir arquivo…") { pickFile() }
                Button("Transmitir link…") { link = ""; askingLink = true }
                Divider()
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
        .alert("Transmitir link", isPresented: $askingLink) {
            TextField("https://…/video.mp4", text: $link)
            Button("Cancelar", role: .cancel) {}
            Button("Transmitir") {
                if let url = URL(string: link.trimmingCharacters(in: .whitespaces)) { Task { await store.cast(url) } }
            }
        } message: {
            Text("Link direto para vídeo, música, imagem ou HLS (.m3u8).")
        }
        .confirmationDialog("Reiniciar o Chromecast?", isPresented: $confirmReboot) {
            Button("Reiniciar", role: .destructive) { store.reboot() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A transmissão atual é interrompida e o aparelho volta em cerca de 1 minuto.")
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.cast(url) }
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
