import SwiftUI
import UniformTypeIdentifiers

private let defaultTint = Color(red: 0.56, green: 0.56, blue: 1.0)
private let panelWidth: CGFloat = 340
private let inner: CGFloat = panelWidth - 32

// MARK: - Serviços

/// Ícone e cor de cada serviço (pela URL ou pelo app aberto na TV).
struct Service {
    let name: String
    let symbol: String
    let fill: AnyShapeStyle

    static func from(url: URL?) -> Service {
        let host = url?.host?.lowercased() ?? ""
        if let url, YouTubeLink(url) != nil { return .youtube }
        if host.hasSuffix("spotify.com") || url?.scheme == "spotify" { return .spotify }
        if host.hasSuffix("instagram.com") { return .instagram }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") { return .x }
        if url?.isFileURL == true { return .file }
        return .web
    }

    static func from(appId: String?, name: String) -> Service {
        switch appId {
        case CastStore.youtubeApp: .youtube
        case CastStore.spotifyApp: .spotify
        case CastStore.defaultReceiver: Service(name: String(localized: "Do Mac"), symbol: "laptopcomputer", fill: AnyShapeStyle(Color.white.opacity(0.15)))
        default: Service(name: name, symbol: "play.tv", fill: AnyShapeStyle(Color.white.opacity(0.15)))
        }
    }

    static let youtube = Service(name: "YouTube", symbol: "play.fill", fill: AnyShapeStyle(Color(red: 1, green: 0.16, blue: 0.16)))
    static let spotify = Service(name: "Spotify", symbol: "music.note", fill: AnyShapeStyle(Color(red: 0.12, green: 0.84, blue: 0.38)))
    static let instagram = Service(name: "Instagram", symbol: "camera", fill: AnyShapeStyle(LinearGradient(
        colors: [Color(red: 0.98, green: 0.76, blue: 0.2), Color(red: 0.93, green: 0.18, blue: 0.45), Color(red: 0.55, green: 0.24, blue: 0.85)],
        startPoint: .bottomLeading, endPoint: .topTrailing)))
    static let x = Service(name: "X", symbol: "xmark", fill: AnyShapeStyle(Color.black))
    static let file = Service(name: String(localized: "Arquivo"), symbol: "doc.fill", fill: AnyShapeStyle(Color.white.opacity(0.15)))
    static let web = Service(name: "Web", symbol: "globe", fill: AnyShapeStyle(Color.white.opacity(0.15)))
}

private struct ServiceIcon: View {
    let service: Service
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(service.fill)
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).stroke(.white.opacity(0.12))
            Image(systemName: service.symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Raiz

struct RootView: View {
    @EnvironmentObject var store: CastStore
    @State private var dropTargeted = false

    private var tint: Color { store.artworkTint ?? defaultTint }

    var body: some View {
        VStack(spacing: 12) {
            Header(tint: tint)
            Banners(tint: tint)

            if !store.connected {
                Searching()
            } else if store.mirroring {
                MirrorActive(tint: tint)
            } else if store.dashboardOn {
                DashboardActive(tint: tint)
            } else if let media = store.media {
                NowPlayingCard(media: media, tint: tint)
            } else if let app = store.app, !app.isIdle {
                AppOnlyCard(app: app, tint: tint)
            }

            if store.connected {
                SendBar(tint: tint)
                if !store.isCasting, !store.dashboardOn, !store.mirroring { IdleHome(tint: tint) }
                VolumeRow(tint: tint)
                if store.isCasting, !store.dashboardOn, !store.mirroring { SleepRow(tint: tint) }
            }
            Footer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: panelWidth)
        .background { Backdrop(tint: tint) }
        .overlay { if dropTargeted { DropOverlay(tint: tint) } }
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted, perform: handleDrop)
        .animation(.snappy, value: dropTargeted)
        .animation(.snappy, value: store.castProgress)
        .animation(.snappy, value: store.notice)
        .animation(.snappy, value: store.media == nil)
        .environment(\.colorScheme, .dark)
        .tint(tint)
        .task {
            store.requestStatus()
            await store.refreshBrowserTab()
        }
    }

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

/// Vidro + capa desfocada (ou o tom da capa) atrás de tudo.
private struct Backdrop: View {
    @EnvironmentObject var store: CastStore
    let tint: Color
    var body: some View {
        ZStack {
            Glass()
            Color.black.opacity(0.42)
            if let img = store.artworkImage, store.isCasting, !SnapshotMode.isOn {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 60).opacity(0.35)
                    .frame(width: panelWidth).clipped()
            }
            RadialGradient(colors: [tint.opacity(store.isCasting ? 0.30 : 0.12), .clear],
                           center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: 320)
        }
        .animation(.easeInOut(duration: 0.6), value: store.artworkTint)
    }
}

private struct DropOverlay: View {
    let tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.6)))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "tv.and.mediabox").font(.system(size: 32, weight: .light))
                    Text("Solte para tocar na TV").font(.system(size: 14, weight: .semibold))
                    Text("Vídeo, música, foto ou link").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .foregroundStyle(tint)
            }
            .padding(6)
            .transition(.opacity)
    }
}

// MARK: - Cabeçalho

private struct Header: View {
    @EnvironmentObject var store: CastStore
    let tint: Color
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmReboot = false

    private var status: String {
        guard store.connected else {
            return store.reconnecting ? String(localized: "Reconectando…") : String(localized: "Conectando…")
        }
        if store.mirroring { return String(localized: "Espelhando a tela") }
        if store.dashboardOn { return String(localized: "Mostrando o painel") }
        guard let app = store.app else { return String(localized: "Pronto") }
        if app.isIdle { return String(localized: "Pronto para transmitir") }
        if let m = store.media {
            return m.isPlaying ? String(localized: "Tocando no \(app.name)") : String(localized: "Pausado no \(app.name)")
        }
        return String(localized: "Transmitindo \(app.name)")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.isCasting ? "tv.fill" : "tv")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(store.isCasting ? tint : .primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(store.isCasting ? tint.opacity(0.18) : .white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 1) {
                if store.devices.count > 1 {
                    Menu(store.displayName) {
                        ForEach(store.devices) { d in Button(d.name) { store.selectedId = d.id } }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 14, weight: .semibold))
                } else {
                    Text(store.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.connected ? (store.isCasting ? tint : .green) : .orange)
                        .opacity(store.connected ? 1 : 0.8)
                        .frame(width: 6, height: 6)
                    Text(status).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)

            if store.isCasting {
                Button(action: store.stopCasting) {
                    Label("Parar", systemImage: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Parar transmissão"))
            }

            Menu {
                Button("Transmitir arquivo…") { pickFile() }
                Toggle("Usar login do navegador (Instagram e X)", isOn: $store.useBrowserLogin)
                Toggle("Som do Mac no modo compatível", isOn: $store.mirrorAudio)
                Divider()
                Button("Renomear…") { newName = store.displayName; renaming = true }
                Button("Reiniciar Chromecast…") { confirmReboot = true }
                Button("Reconectar") { store.reconnectNow() }
                if !store.recents.isEmpty { Button("Limpar recentes") { store.clearRecents() } }
                Divider()
                Button("Fechar app") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .alert("Renomear Chromecast", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") { store.rename(to: newName) }
        } message: {
            Text("O novo nome aparece no celular, no navegador e aqui.")
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
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Task { await store.cast(url) } }
    }
}

// MARK: - Avisos

private struct Banners: View {
    @EnvironmentObject var store: CastStore
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            if let p = store.castProgress {
                banner(icon: nil, text: p, color: tint, dismiss: nil)
            }
            if let n = store.notice {
                banner(icon: "info.circle.fill", text: n, color: tint) { store.notice = nil }
            }
            if let e = store.error, store.connected {
                banner(icon: "exclamationmark.triangle.fill", text: e, color: .orange) { store.error = nil }
            }
        }
    }

    private func banner(icon: String?, text: String, color: Color, dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            } else {
                ProgressView().controlSize(.mini).padding(.top, 1)
            }
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(color.opacity(0.25)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Enviar para a TV

private struct SendBar: View {
    @EnvironmentObject var store: CastStore
    let tint: Color
    @State private var link = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Cole um link pra transmitir", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(send)
                if link.isEmpty {
                    Button("Colar", action: pasteAndSend)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .help(String(localized: "Colar o link copiado e transmitir"))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)).foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(focused ? 0.1 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(focused ? tint.opacity(0.6) : .white.opacity(0.06)))

            if let tab = store.browserTab {
                BrowserTabRow(tab: tab, tint: tint)
            }
        }
    }

    private func send() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil else { return }
        link = ""
        focused = false
        Task { await store.cast(url) }
    }

    private func pasteAndSend() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: s), url.scheme?.hasPrefix("http") == true else {
            store.notice = String(localized: "A área de transferência não tem um link.")
            return
        }
        Task { await store.cast(url) }
    }
}

private struct BrowserTabRow: View {
    @EnvironmentObject var store: CastStore
    let tab: BrowserTab
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            ServiceIcon(service: .from(url: tab.url))

            VStack(alignment: .leading, spacing: 1) {
                Text("Aba do \(tab.browser)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            CastButton(tint: tint, queueable: YouTubeLink(tab.url) != nil && store.youtubeOnTV) { action in
                Task { await store.castBrowserTab(youtube: action) }
            }
            .help(String(localized: "Manda esta aba para a TV (⌃⌥T de qualquer lugar)"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.05)))
    }
}

/// "Transmitir"; com o YouTube já tocando na TV ganha uma seta com: agora / a seguir / fila.
private struct CastButton: View {
    let tint: Color
    let queueable: Bool
    let action: (YouTubeLounge.Action) -> Void
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 1.5) {
            Button { action(.playNow) } label: {
                Text("Transmitir").font(.system(size: 11, weight: .bold))
                    .padding(.leading, 11).padding(.trailing, queueable ? 8 : 11).frame(height: 26)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13,
                                                       bottomTrailingRadius: queueable ? 4 : 13, topTrailingRadius: queueable ? 4 : 13)
                        .fill(tint))
            }
            .buttonStyle(.plain)
            if queueable {
                Button { showOptions.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
                        .frame(width: 22, height: 26)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4,
                                                           bottomTrailingRadius: 13, topTrailingRadius: 13).fill(tint))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        option("Tocar agora", "play.fill", .playNow)
                        option("Tocar a seguir", "text.line.first.and.arrowtriangle.forward", .playNext)
                        option("Adicionar à fila", "text.badge.plus", .addToQueue)
                    }
                    .padding(6)
                }
            }
        }
        .foregroundStyle(.black)
    }

    private func option(_ title: LocalizedStringKey, _ symbol: String, _ a: YouTubeLounge.Action) -> some View {
        Button { showOptions = false; action(a) } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Tocando agora

private struct NowPlayingCard: View {
    @EnvironmentObject var store: CastStore
    let media: MediaState
    let tint: Color

    private var appName: String { store.app?.name ?? "" }
    private var isImage: Bool { media.duration == nil && !media.canSeek && media.playerState == "PAUSED" }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Artwork(url: media.artwork, tint: tint)
                AppBadge(service: .from(appId: store.app?.appId, name: appName))
                    .padding(10)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(media.title ?? appName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                if let sub = media.subtitle, !sub.isEmpty {
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if media.duration != nil, media.canSeek {
                Scrubber(media: media, tint: tint)
            }

            if !isImage {
                HStack(spacing: 30) {
                    RoundIcon(symbol: "gobackward.10", size: 38) { store.skip(-10) }
                        .disabled(!media.canSeek).opacity(media.canSeek ? 1 : 0.35)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button(action: store.togglePlay) {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(.black)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(tint.gradient))
                            .shadow(color: tint.opacity(0.5), radius: 12)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    RoundIcon(symbol: "goforward.30", size: 38) { store.skip(30) }
                        .disabled(!media.canSeek).opacity(media.canSeek ? 1 : 0.35)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .overlay(alignment: .trailing) {
                    if store.youtubeOnTV {
                        RoundIcon(symbol: "forward.end.fill", size: 30) { store.youtubeNext() }
                            .help(String(localized: "Próximo da fila"))
                            .offset(x: 46)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.07)))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

private struct AppBadge: View {
    let service: Service
    var body: some View {
        HStack(spacing: 6) {
            ServiceIcon(service: service, size: 16)
            Text(service.name).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .bold))
        .padding(.leading, 4).padding(.trailing, 9).frame(height: 24)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }
}

private struct Artwork: View {
    let url: URL?
    let tint: Color
    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.tv").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.55))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill).transition(.opacity) }
                }
            }
        }
        .frame(width: inner - 24, height: (inner - 24) * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
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
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule().fill(tint).frame(width: max(0, w * pos / duration))
                        Circle().fill(.white).frame(width: 12, height: 12)
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

private struct AppOnlyCard: View {
    let app: ReceiverApp
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 14, weight: .semibold))
                Text(app.statusText.isEmpty ? String(localized: "Este app não expõe controles de mídia.") : app.statusText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
    }
}

// MARK: - Tela inicial (nada tocando)

private struct IdleHome: View {
    @EnvironmentObject var store: CastStore
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Tile(symbol: "rectangle.3.group", title: String(localized: "Painel"), tint: tint, action: store.startDashboard)
                    .help(String(localized: "Relógio e clima na TV"))
                Tile(symbol: "power", title: String(localized: "Ligar TV"), tint: tint, action: store.turnOnTV)
                    .help(String(localized: "Liga a TV e troca a entrada (HDMI-CEC)"))
                Tile(symbol: "folder", title: String(localized: "Arquivo"), tint: tint, action: pickFile)
                    .help(String(localized: "Vídeo, música ou foto do Mac"))
                Tile(symbol: "rectangle.on.rectangle", title: String(localized: "Espelhar"), tint: tint) {
                    Task { await store.startMirroring() }
                }
                .help(String(localized: "Mostra a tela do Mac na TV, quase sem atraso"))
            }

            if !store.recents.isEmpty {
                Text("Recentes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(spacing: 2) {
                    ForEach(store.recents.prefix(4)) { r in RecentRow(item: r, tint: tint) }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").foregroundStyle(.secondary)
                    Text("Dica: arraste um arquivo ou link pra cá, ou use ⌃⌥T no navegador.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { Task { await store.cast(url) } }
    }
}

private struct Tile: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentRow: View {
    @EnvironmentObject var store: CastStore
    let item: RecentCast
    let tint: Color
    @State private var hover = false

    var body: some View {
        Button {
            if let url = URL(string: item.url) { Task { await store.cast(url, title: item.title) } }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08))
                        if let s = item.image, let u = URL(string: s) {
                            AsyncImage(url: u) { p in p.image?.resizable().aspectRatio(contentMode: .fill) }
                        }
                    }
                    .frame(width: 52, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    ServiceIcon(service: .from(url: URL(string: item.url)), size: 15)
                        .offset(x: 4, y: 4)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            if let url = URL(string: item.url) {
                Button("Tocar agora") { Task { await store.cast(url, title: item.title) } }
                if YouTubeLink(url) != nil, store.youtubeOnTV {
                    Button("Tocar a seguir") { Task { await store.cast(url, title: item.title, youtube: .playNext) } }
                    Button("Adicionar à fila") { Task { await store.cast(url, title: item.title, youtube: .addToQueue) } }
                }
            }
        }
    }
}

private struct Searching: View {
    @EnvironmentObject var store: CastStore
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.devices.isEmpty ? String(localized: "Procurando Chromecast na rede…")
                 : store.reconnecting ? String(localized: "Reconectando ao \(store.displayName)…")
                 : String(localized: "Conectando ao \(store.displayName)…"))
                .font(.system(size: 12, weight: .medium))
            if let e = store.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else if store.devices.isEmpty {
                Text("Se nada aparecer, libere o app em Ajustes do Sistema → Privacidade e Segurança → Rede Local.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !store.devices.isEmpty {
                Button(action: store.reconnectNow) {
                    Label("Tentar agora", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct MirrorActive: View {
    @EnvironmentObject var store: CastStore
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.15))
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 20, weight: .light)).foregroundStyle(tint)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("AO VIVO")
                            .font(.system(size: 9, weight: .heavy)).tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(Capsule().fill(.red))
                        Text("Espelhando a tela").font(.system(size: 14, weight: .semibold))
                    }
                    Text(store.mirrorInstant ? String(localized: "Modo instantâneo — quase sem atraso.")
                         : String(localized: "Modo compatível — alguns segundos de atraso."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Label(store.mirrorInstant ? String(localized: "O som continua saindo do Mac, em sincronia com a TV.")
                  : store.mirrorAudio ? String(localized: "Som do Mac vai junto (abaixe o volume do Mac pra não ter eco)")
                  : String(localized: "Só imagem (o som fica no Mac)"),
                  systemImage: store.mirrorInstant ? "speaker.wave.2" : store.mirrorAudio ? "speaker.wave.2" : "speaker.slash")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: store.stopMirroring) {
                Label("Parar de espelhar", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06)))
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
            .frame(width: inner, height: inner * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.1)))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Painel da casa na TV").font(.system(size: 13, weight: .semibold))
                    Text("Atualiza a cada minuto").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.stopDashboard) {
                    Text("Desligar").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
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
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in change(to: g.location.x / w) })
            }
            .frame(height: 20)

            Text("\(Int((store.volume * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            Group {
                Button("") { change(to: store.volume + store.volumeStep) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { change(to: store.volume - store.volumeStep) }.keyboardShortcut(.downArrow, modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .help(String(localized: "⌃⌥↑ / ⌃⌥↓ mudam o volume de qualquer lugar"))
    }

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
            if let at = store.sleepAt { active(at).transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { picker.transition(.opacity) }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .animation(.snappy, value: store.sleepAt == nil)
    }

    private var picker: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.zzz").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22)
            Text("Dormir em").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 2)
            ForEach([(15, "15m"), (30, "30m"), (60, "1h")], id: \.0) { m, label in
                chip(label) { store.startSleep(minutes: m) }
            }
            if store.media?.duration != nil {
                chip(String(localized: "Fim"), width: 38) { store.sleepAtEndOfEpisode() }
                    .help(String(localized: "Parar quando o episódio acabar"))
            }
        }
    }

    private func chip(_ label: String, width: CGFloat = 34, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10.5, weight: .semibold))
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
                    Circle().trim(from: 0, to: 1 - store.sleepProgress(at: ctx.date))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "moon.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: store.fading)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(remaining(at.timeIntervalSince(ctx.date)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(store.fading ? String(localized: "Abaixando o volume…")
                         : store.sleepMode == .endOfEpisode ? String(localized: "No fim do episódio")
                         : String(localized: "Para às \(at.formatted(date: .omitted, time: .shortened))"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                chip("+15m", width: 44) { store.extendSleep(minutes: 15) }
                Button(action: store.cancelSleep) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.08)))
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
    var body: some View {
        HStack(spacing: 6) {
            if let info = store.info {
                if let s = info.signal {
                    Image(systemName: "wifi", variableValue: min(max(Double(s + 85) / 45, 0.05), 1))
                        .help(info.ssid.map { "\($0) · \(s) dBm" } ?? "\(s) dBm")
                }
                Text(info.firmware.isEmpty ? "Chromecast" : "Cast \(info.firmware)").lineLimit(1)
            } else if let d = store.device {
                Text(d.model)
            }
            Spacer()
            Text("⌃⌥T aba · ⌃⌥↑↓ volume").lineLimit(1)
            Button(action: { store.requestStatus(); store.requestDeviceInfo(); Task { await store.refreshBrowserTab() } }) {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
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
