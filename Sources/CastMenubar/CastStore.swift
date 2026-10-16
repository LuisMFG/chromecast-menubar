import AppKit
import Foundation
import Network
import SwiftUI
import Carbon.HIToolbox
import os

let log = Logger(subsystem: "dev.local.CastMenubar", category: "cast")

struct CastDevice: Identifiable, Hashable {
    let id: String          // nome do serviço Bonjour
    let name: String        // TXT "fn"
    let model: String       // TXT "md"
    let endpoint: NWEndpoint
}

struct DeviceInfo: Equatable {
    var name: String
    var firmware: String
    var signal: Int?
    var ssid: String?
    var timezone: String?
}

struct ReceiverApp: Equatable {
    var appId: String
    var name: String
    var statusText: String
    var isIdle: Bool
    var sessionId: String
    var transportId: String
    var hasMedia: Bool
}

struct MediaState: Equatable {
    var sessionId: Int
    var playerState: String          // PLAYING, PAUSED, BUFFERING, IDLE
    var currentTime: Double
    var updatedAt: Date
    var rate: Double
    var duration: Double?
    var title: String?
    var subtitle: String?
    var artwork: URL?
    var canSeek: Bool
    var canPause: Bool

    var isPlaying: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }

    func position(at now: Date) -> Double {
        // só avança durante PLAYING: em BUFFERING o tempo fica parado (o YouTube na 1ª geração demora pra começar)
        let t = playerState == "PLAYING" ? currentTime + now.timeIntervalSince(updatedAt) * rate : currentTime
        if let duration, duration > 0 { return min(max(t, 0), duration) }
        return max(t, 0)
    }
}

@MainActor
final class CastStore: ObservableObject {
    @Published var devices: [CastDevice] = []
    @Published var selectedId: String? { didSet { if oldValue != selectedId { connect() } } }
    @Published var connected = false
    @Published var app: ReceiverApp?
    @Published var media: MediaState?
    @Published var volume: Double = 0
    @Published var muted = false
    @Published var volumeStep: Double = 0.05
    @Published var artworkTint: Color?
    @Published private(set) var artworkImage: NSImage?
    /// Erros somem sozinhos depois de alguns segundos (os de conexão continuam até reconectar).
    @Published var error: String? {
        didSet {
            errorClear?.cancel()
            guard error != nil, connected else { return }
            errorClear = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { self?.error = nil }
            }
        }
    }
    private var errorClear: Task<Void, Never>?
    @Published var info: DeviceInfo?
    /// Texto de progresso ao preparar uma transmissão ("Convertendo 40%", "Abrindo…")
    @Published var castProgress: String?
    /// Aviso informativo (não é erro): Spotify, DRM, dicas.
    @Published var notice: String? {
        didSet {
            noticeClear?.cancel()
            guard notice != nil else { return }
            noticeClear = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { self?.notice = nil }
            }
        }
    }
    private var noticeClear: Task<Void, Never>?
    @Published var browserTab: BrowserTab?
    /// Deixa o yt-dlp usar a sessão do navegador (Instagram/X). Desligado por padrão.
    @Published var useBrowserLogin = UserDefaults.standard.bool(forKey: "useBrowserLogin") {
        didSet { UserDefaults.standard.set(useBrowserLogin, forKey: "useBrowserLogin") }
    }
    @Published private(set) var recents: [RecentCast] = []
    @Published private(set) var dashboardOn = false
    @Published private(set) var mirroring = false
    /// Mandar o som do Mac pra TV ao espelhar.
    @Published var mirrorAudio = UserDefaults.standard.object(forKey: "mirrorAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mirrorAudio, forKey: "mirrorAudio") }
    }
    /// Silenciar o Mac enquanto o som vai pra TV (evita eco).
    @Published var muteMacWhileMirroring = UserDefaults.standard.object(forKey: "muteMac") as? Bool ?? true {
        didSet { UserDefaults.standard.set(muteMacWhileMirroring, forKey: "muteMac") }
    }
    /// Perfil do espelhamento: fluido (vídeos) ou atraso mínimo (apresentação).
    @Published var mirrorLowLatency = UserDefaults.standard.bool(forKey: "mirrorLowLatency") {
        didSet { UserDefaults.standard.set(mirrorLowLatency, forKey: "mirrorLowLatency") }
    }
    /// A TV aceitou o fluxo de áudio nesta sessão.
    @Published private(set) var mirrorHasAudio = false
    private var mirror: ScreenMirror?
    private var streamer: CastStreamer?
    private var streamerOffered = false
    /// Modo do espelhamento em uso (instantâneo = Cast Streaming; compatível = HLS).
    @Published private(set) var mirrorInstant = false
    private var mirrorShown = false
    static let mirrorTitle = String(localized: "Tela do Mac")
    @Published private(set) var dashboardPreview: NSImage?

    private var browser: NWBrowser?
    private var channel: CastChannel?
    private var mediaTransport: String?
    private var requestId = 1
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var attempt = 0
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false
    /// Reconectando depois de uma queda (a UI mostra isso em vez de "Desconectado").
    @Published private(set) var reconnecting = false
    private var volumeTask: Task<Void, Never>?
    private var lastArtwork: URL?
    private var setupRequestId = 1
    private var pendingLoad: [String: Any]?
    private var dashboardTask: Task<Void, Never>?
    private var dashboardShown = false
    private var pendingTurnOn = false
    private let weather = WeatherService()
    static let dashboardTitle = "Chromecast — painel"
    static let defaultReceiver = "CC1AD845"
    static let youtubeApp = "233637DE"
    static let spotifyApp = "CC32E753"
    private var pendingYouTube: YouTubeLink?
    private var pendingYouTubeAction: YouTubeLounge.Action = .playNow
    /// screenId do YouTube aberto na TV (vale enquanto o app do YouTube estiver lá).
    private var youtubeScreenId: String?
    var youtubeOnTV: Bool { app?.appId == Self.youtubeApp }
    private var youtubeTransportAsked: String?
    private let lounge = YouTubeLounge()
    private lazy var tabs = BrowserWatcher()

    // Timer de sono
    enum SleepMode: Equatable { case duration, endOfEpisode }
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepStart: Date?
    @Published private(set) var sleepMode: SleepMode = .duration
    @Published private(set) var fading = false
    private var sleepTask: Task<Void, Never>?
    private var volumeBeforeFade: Double?
    private var sleepActivity: NSObjectProtocol?
    private var isPreview = false
    private lazy var nowPlaying = NowPlayingBridge(store: self)
    private var pollCount = 0

    var device: CastDevice? { devices.first { $0.id == selectedId } }
    var displayName: String { info?.name ?? device?.name ?? "Chromecast" }
    var isCasting: Bool { app.map { !$0.isIdle } ?? false }

    init() {
        startBrowsing()
        registerHotKeys()
        loadRecents()
        observeSystem()
        // se o Bonjour demorar ou falhar, usa o último IP conhecido
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.useCachedDeviceIfNeeded()
        }
        NotificationCenter.default.addObserver(forName: .castFiles, object: nil, queue: .main) { [weak self] n in
            guard let urls = n.object as? [URL], let url = urls.first else { return }
            Task { @MainActor in await self?.cast(url) }
        }
    }

    /// Store com dados fictícios, usado só pra gerar snapshots da interface.
    init(preview app: ReceiverApp?, media: MediaState?, volume: Double, tint: Color? = nil,
         tab: BrowserTab? = nil, recents: [RecentCast] = [], mirroring: Bool = false) {
        isPreview = true
        self.mirroring = mirroring
        self.mirrorInstant = mirroring
        let room = String(localized: "Sala")
        devices = [CastDevice(id: "preview", name: room, model: "Chromecast", endpoint: .hostPort(host: "127.0.0.1", port: 8009))]
        selectedId = "preview"
        connected = true
        self.app = app
        self.media = media
        self.volume = volume
        self.artworkTint = tint
        self.browserTab = tab
        self.recents = recents
        info = DeviceInfo(name: room, firmware: "1.56.467165", signal: -44, ssid: nil, timezone: nil)
    }

    // MARK: - Descoberta (Bonjour _googlecast._tcp)

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [CastDevice] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = r.metadata { txt = record.dictionary }
                return CastDevice(id: name, name: txt["fn"] ?? name, model: txt["md"] ?? "Chromecast", endpoint: r.endpoint)
            }
            Task { @MainActor in self?.updateDevices(found) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case let .failed(err) = state {
                Task { @MainActor in self?.error = err.localizedDescription }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func updateDevices(_ found: [CastDevice]) {
        var list = found
        // o Bonjour às vezes "esquece" o aparelho por alguns segundos: não derruba quem já está selecionado
        if let current = device, !list.contains(where: { $0.id == current.id }) { list.append(current) }
        devices = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedId == nil || !devices.contains(where: { $0.id == selectedId }) {
            let saved = UserDefaults.standard.string(forKey: "device")
            selectedId = devices.first { $0.id == saved }?.id ?? devices.first?.id
        }
    }

    /// Aparelho montado a partir do último IP que funcionou.
    private func useCachedDeviceIfNeeded() {
        guard devices.isEmpty, !isPreview,
              let ip = UserDefaults.standard.string(forKey: "lastIP")?.split(separator: "%").first.map(String.init),
              let id = UserDefaults.standard.string(forKey: "device") else { return }
        let name = UserDefaults.standard.string(forKey: "lastName") ?? "Chromecast"
        devices = [CastDevice(id: id, name: name, model: "Chromecast", endpoint: .hostPort(host: NWEndpoint.Host(ip), port: 8009))]
        selectedId = id
    }

    // MARK: - Conexão

    /// Conecta (ou reconecta) ao aparelho selecionado. Seguro de chamar a qualquer momento.
    func connect() {
        guard !isPreview else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        connectTimeout?.cancel()
        pollTask?.cancel()
        channel?.stop()          // solta os callbacks antes: a conexão antiga não pode disparar reconexão
        channel = nil
        mediaTransport = nil
        youtubeTransportAsked = nil
        connected = false
        guard let device else { return }
        UserDefaults.standard.set(device.id, forKey: "device")
        UserDefaults.standard.set(device.name, forKey: "lastName")

        // depois de 2 falhas pelo Bonjour, tenta direto o último IP que funcionou
        var endpoint = device.endpoint
        if attempt >= 2, let ip = UserDefaults.standard.string(forKey: "lastIP")?.split(separator: "%").first.map(String.init) {
            endpoint = .hostPort(host: NWEndpoint.Host(ip), port: 8009)
        }
        let ch = CastChannel(endpoint: endpoint)
        ch.onMessage = { [weak self, weak ch] msg in
            Task { @MainActor in
                guard let self, let ch, self.channel === ch else { return }
                self.handle(msg)
            }
        }
        ch.onState = { [weak self, weak ch] state in
            Task { @MainActor in
                guard let self, let ch, self.channel === ch else { return }   // ignora estados de conexões velhas
                self.channelState(state)
            }
        }
        channel = ch
        ch.start()

        // conexão presa em "preparando" (Wi-Fi do aparelho dormindo, rota quebrada): desiste e tenta de novo
        connectTimeout = Task { [weak self, weak ch] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let ch, self.channel === ch, !self.connected else { return }
            self.dropAndReconnect()
        }
    }

    private func channelState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectTimeout?.cancel()
            connected = true
            reconnecting = false
            attempt = 0
            error = nil
            if let ip = channel?.remoteAddress { UserDefaults.standard.set(ip, forKey: "lastIP") }
            requestStatus()
            requestDeviceInfo()
            startPolling()
            startWatchdog()
        case .failed, .cancelled, .waiting:
            dropAndReconnect()
        default: break
        }
    }

    /// Marca como caído e agenda nova tentativa com espera crescente (1, 2, 4, 8, 15 s).
    private func dropAndReconnect(immediately: Bool = false) {
        channel?.stop()
        channel = nil
        connected = false
        pollTask?.cancel()
        watchdogTask?.cancel()
        guard device != nil else { return }
        reconnecting = true
        if attempt >= 4 {
            // o caso mais comum: o Chromecast é alimentado pela USB da TV e desligou junto com ela
            error = String(localized: "O Chromecast não está respondendo — se ele está na USB da TV, desliga junto com ela. Ligue a TV e o app reconecta sozinho.")
        }
        guard reconnectTask == nil else { return }       // não empilha tentativas
        let delay = immediately ? 0.2 : min(pow(2, Double(attempt)), 15) * Double.random(in: 0.8...1.2)
        attempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
    }

    /// Botão "Tentar agora": zera a espera.
    func reconnectNow() {
        attempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        connect()
    }

    /// Conexão "zumbi": o aparelho responde o heartbeat a cada 5 s; 15 s de silêncio = caiu.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.connected, let ch = self.channel else { continue }
                if ch.silence > 15 {
                    self.attempt = 0
                    self.dropAndReconnect(immediately: true)
                }
            }
        }
    }

    /// Mac acordou ou a rede voltou/mudou: a conexão antiga quase sempre morreu, reconecta na hora.
    private func observeSystem() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.attempt = 0
                self?.dropAndReconnect(immediately: true)
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status != .satisfied { self.networkWasDown = true; return }
                if self.networkWasDown {
                    self.networkWasDown = false
                    self.attempt = 0
                    self.dropAndReconnect(immediately: true)
                }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.requestStatus()
                self?.pollCount += 1
                if (self?.pollCount ?? 0) % 6 == 0 { self?.requestDeviceInfo() }
            }
        }
    }

    func requestStatus() {
        send(to: "receiver-0", ns: CastNS.receiver, ["type": "GET_STATUS"])
        if let t = mediaTransport { send(to: t, ns: CastNS.media, ["type": "GET_STATUS"]) }
    }

    private func send(to dest: String, ns: String, _ payload: [String: Any]) {
        var p = payload
        p["requestId"] = requestId
        requestId += 1
        channel?.send(to: dest, ns: ns, p)
    }

    // MARK: - Mensagens

    private func handle(_ msg: CastMessage) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(msg.payload.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if msg.namespace == CastNS.setup { return setupResponse(type, obj) }
        if msg.namespace == CastNS.youtube { return youtubeMessage(type, obj) }
        if msg.namespace == CastStreamer.namespace { return streamingMessage(type, obj) }
        switch type {
        case "RECEIVER_STATUS":
            if let status = obj["status"] as? [String: Any] { receiverStatus(status) }
        case "MEDIA_STATUS":
            if let list = obj["status"] as? [[String: Any]] { mediaStatus(list.first) }
        case "CLOSE":
            if msg.source == mediaTransport { mediaTransport = nil; media = nil }
        default: break
        }
    }

    private func receiverStatus(_ s: [String: Any]) {
        if let v = s["volume"] as? [String: Any] {
            if volumeTask == nil, let level = v["level"] as? Double { volume = level }
            muted = v["muted"] as? Bool ?? false
            if let step = v["stepInterval"] as? Double, step > 0 { volumeStep = step }
        }
        guard let a = (s["applications"] as? [[String: Any]])?.first else {
            app = nil; media = nil; mediaTransport = nil
            publishNowPlaying()
            return
        }
        let namespaces = (a["namespaces"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let newApp = ReceiverApp(
            appId: a["appId"] as? String ?? "",
            name: a["displayName"] as? String ?? "",
            statusText: a["statusText"] as? String ?? "",
            isIdle: a["isIdleScreen"] as? Bool ?? false,
            sessionId: a["sessionId"] as? String ?? "",
            transportId: a["transportId"] as? String ?? "",
            hasMedia: namespaces.contains(CastNS.media))
        withAnimation(.snappy) { app = newApp }

        if newApp.hasMedia, mediaTransport != newApp.transportId {
            mediaTransport = newApp.transportId
            send(to: newApp.transportId, ns: CastNS.connection, ["type": "CONNECT"])
            send(to: newApp.transportId, ns: CastNS.media, ["type": "GET_STATUS"])
        }
        if newApp.appId != Self.youtubeApp { youtubeScreenId = nil }
        // YouTube aberto (por nós ou pelo celular): pega o screenId pra permitir fila
        if newApp.appId == Self.youtubeApp, youtubeScreenId == nil, pendingYouTube == nil,
           youtubeTransportAsked != newApp.transportId, !newApp.transportId.isEmpty {
            youtubeTransportAsked = newApp.transportId
            send(to: newApp.transportId, ns: CastNS.connection, ["type": "CONNECT"])
            channel?.send(to: newApp.transportId, ns: CastNS.youtube, ["type": "getMdxSessionStatus"])
        }
        if pendingYouTube != nil, newApp.appId == Self.youtubeApp, !newApp.transportId.isEmpty,
           youtubeTransportAsked != newApp.transportId {
            youtubeTransportAsked = newApp.transportId
            send(to: newApp.transportId, ns: CastNS.connection, ["type": "CONNECT"])
            channel?.send(to: newApp.transportId, ns: CastNS.youtube, ["type": "getMdxSessionStatus"])
        }
        if pendingTurnOn, newApp.appId == Self.defaultReceiver {
            pendingTurnOn = false
            send(to: "receiver-0", ns: CastNS.receiver, ["type": "STOP", "sessionId": newApp.sessionId])
        }
        // painel ativo e alguém transmitiu outra coisa: sai do modo painel
        if dashboardOn, dashboardShown, newApp.appId != Self.defaultReceiver {
            endDashboard()
        }
        if mirroring, mirrorShown, !mirrorInstant, newApp.appId != Self.defaultReceiver {
            endMirroring()
        }
        if mirroring, mirrorInstant {
            if newApp.appId == CastStreamer.receiverApp, let st = streamer, !streamerOffered {
                streamerOffered = true
                mirrorShown = true
                send(to: newApp.transportId, ns: CastNS.connection, ["type": "CONNECT"])
                channel?.send(to: newApp.transportId, ns: CastStreamer.namespace, st.offer(seqNum: Int.random(in: 1...100_000)))
                log.notice("mirror: OFFER enviado (\(st.width)x\(st.height) h264)")
            } else if mirrorShown, newApp.appId != CastStreamer.receiverApp {
                endMirroring()      // outra coisa assumiu a TV
            }
        }
        if let load = pendingLoad, newApp.appId == Self.defaultReceiver, newApp.hasMedia {
            pendingLoad = nil
            send(to: newApp.transportId, ns: CastNS.media, load)
            castProgress = nil
        } else if !newApp.hasMedia {
            mediaTransport = nil
            media = nil
            publishNowPlaying()
        }
    }

    private func mediaStatus(_ s: [String: Any]?) {
        defer { publishNowPlaying() }
        guard let s, let sid = s["mediaSessionId"] as? Int else { media = nil; return }
        let info = s["media"] as? [String: Any]
        let meta = info?["metadata"] as? [String: Any]
        let images = (meta?["images"] as? [[String: Any]])?.compactMap { $0["url"] as? String } ?? []
        let commands = s["supportedMediaCommands"] as? Int ?? 0xFFFF
        let previous = media
        let new = MediaState(
            sessionId: sid,
            playerState: s["playerState"] as? String ?? "IDLE",
            currentTime: s["currentTime"] as? Double ?? 0,
            updatedAt: Date(),
            rate: s["playbackRate"] as? Double ?? 1,
            duration: (info?["duration"] as? Double) ?? previous?.duration,
            // status parciais (só tempo/estado) não trazem metadados: mantém os anteriores
            title: (meta?["title"] as? String) ?? (info == nil ? previous?.title : nil),
            subtitle: (meta?["subtitle"] as? String) ?? (meta?["artist"] as? String) ?? (meta?["seriesTitle"] as? String)
                ?? (info == nil ? previous?.subtitle : nil),
            artwork: images.first.flatMap(URL.init(string:)) ?? (info == nil ? previous?.artwork : nil),
            canSeek: commands & 2 != 0,
            canPause: commands & 1 != 0)
        if new.playerState == "IDLE", new.title == nil { media = nil; return }
        if dashboardOn {
            if new.title == Self.dashboardTitle { dashboardShown = true }
            else if dashboardShown, new.title != nil { endDashboard() }
        }
        // só no modo HLS o título identifica o espelhamento; o receptor instantâneo chama de "Chrome tab casting"
        if mirroring, !mirrorInstant {
            if new.title == Self.mirrorTitle { mirrorShown = true }
            else if mirrorShown, new.title != nil { endMirroring() }
        }
        withAnimation(.snappy) { media = new }
        loadTint(for: new.artwork)
    }

    // MARK: - Comandos

    func togglePlay() {
        guard let m = media, let t = mediaTransport else { return }
        let playing = m.isPlaying
        media?.currentTime = m.position(at: Date())
        media?.updatedAt = Date()
        media?.playerState = playing ? "PAUSED" : "PLAYING"
        send(to: t, ns: CastNS.media, ["type": playing ? "PAUSE" : "PLAY", "mediaSessionId": m.sessionId])
        publishNowPlaying()
    }

    func seek(to time: Double) {
        guard let m = media, let t = mediaTransport else { return }
        let time = max(0, min(time, m.duration ?? time))
        media?.currentTime = time
        media?.updatedAt = Date()
        send(to: t, ns: CastNS.media, ["type": "SEEK", "mediaSessionId": m.sessionId, "currentTime": time])
        publishNowPlaying()
    }

    func skip(_ seconds: Double) {
        guard let m = media else { return }
        seek(to: m.position(at: Date()) + seconds)
    }

    /// Volume com debounce: a UI muda na hora, o aparelho recebe quando o usuário para de arrastar.
    func setVolume(_ level: Double) {
        let level = fading ? min(max(level, 0), 1) : (min(max(level, 0), 1) / volumeStep).rounded() * volumeStep
        volume = level
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.send(to: "receiver-0", ns: CastNS.receiver, ["type": "SET_VOLUME", "volume": ["level": level]])
            try? await Task.sleep(for: .milliseconds(400))
            self.volumeTask = nil
        }
    }

    func toggleMute() {
        muted.toggle()
        send(to: "receiver-0", ns: CastNS.receiver, ["type": "SET_VOLUME", "volume": ["muted": muted]])
    }

    func stopCasting() {
        guard let a = app, !a.isIdle else { return }
        send(to: "receiver-0", ns: CastNS.receiver, ["type": "STOP", "sessionId": a.sessionId])
    }

    // MARK: - Teclas de mídia e atalhos globais

    private func publishNowPlaying() {
        guard !isPreview, !dashboardOn else { return }
        nowPlaying.update()
    }

    private func registerHotKeys() {
        let mods = controlKey | optionKey
        HotKeys.shared.register(keyCode: kVK_UpArrow, modifiers: mods) { [weak self] in self?.nudgeVolume(+1) }
        HotKeys.shared.register(keyCode: kVK_DownArrow, modifiers: mods) { [weak self] in self?.nudgeVolume(-1) }
        HotKeys.shared.register(keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in
            Task { await self?.castBrowserTab(showHUD: true) }
        }
        HotKeys.shared.register(keyCode: kVK_Space, modifiers: mods) { [weak self] in
            guard let self, let m = self.media else { return }
            self.togglePlay()
            HUD.shared.show(symbol: m.isPlaying ? "pause.fill" : "play.fill",
                            title: m.isPlaying ? String(localized: "Pausado") : String(localized: "Tocando"))
        }
    }

    /// ⌃⌥↑ / ⌃⌥↓: volume da TV de qualquer lugar, com aviso na tela.
    private func nudgeVolume(_ direction: Double) {
        guard connected else { return }
        if muted { toggleMute() }
        setVolume(volume + direction * volumeStep)
        HUD.shared.show(symbol: volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                        title: "\(displayName) · \(Int((volume * 100).rounded()))%", level: volume)
    }

    // MARK: - Transmitir do Mac

    /// Qualquer coisa: arquivo do Mac, YouTube, link direto, página com vídeo, Spotify…
    func cast(_ url: URL, title: String? = nil, youtube action: YouTubeLounge.Action = .playNow) async {
        guard connected else { error = String(localized: "Chromecast desconectado"); return }
        notice = nil
        if mirroring { endMirroring() }
        if !url.isFileURL, YouTubeLink(url) == nil { castProgress = String(localized: "Procurando o vídeo…") }
        let cookies = useBrowserLogin ? tabs.ytdlpBrowserName : nil
        switch await Resolver.resolve(url, cookiesFrom: cookies) {
        case .youtube(let link):
            castYouTube(link, action: action)
            remember(url: url, title: title ?? String(localized: "Vídeo do YouTube"), kind: "youtube",
                     image: "https://i.ytimg.com/vi/\(link.videoId)/hqdefault.jpg")
        case .media(let media, let mime, let found, let image):
            if media.isFileURL { await castFile(media) }
            else { load(contentURL: media.absoluteString, mime: mime, title: title ?? found, image: image) }
            remember(url: url.absoluteString == media.absoluteString ? url : url, title: title ?? found,
                     kind: media.isFileURL ? "file" : "media", image: image?.absoluteString)
        case .spotify(let link):
            castProgress = nil
            openInSpotify(link)
            remember(url: link, title: title ?? String(localized: "Spotify"), kind: "spotify", image: nil)
        case .unsupported(let message):
            castProgress = nil
            notice = message
        }
    }

    /// Aba ativa do navegador → TV. Pausa o vídeo no navegador quando dá.
    func castBrowserTab(showHUD: Bool = false, youtube action: YouTubeLounge.Action = .playNow) async {
        guard let tab = await tabs.activeTab() else {
            notice = String(localized: "Nenhuma aba de navegador encontrada (Brave, Chrome, Safari, Arc ou Edge).")
            return
        }
        browserTab = tab
        if showHUD { HUD.shared.show(symbol: "tv.and.mediabox", title: String(localized: "Enviando para a TV")) }
        await cast(tab.url, title: tab.title.isEmpty ? nil : cleanTitle(tab.title), youtube: action)
        if error == nil, notice == nil { BrowserWatcher.pauseVideo(in: tab) }
    }

    func refreshBrowserTab() async {
        guard !isPreview else { return }
        browserTab = await tabs.activeTab()
    }

    /// "Vídeo X - YouTube" → "Vídeo X"
    private func cleanTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s[-–|]\s(YouTube|YouTube Music|Vimeo|Twitch)$"#, with: "", options: .regularExpression)
    }

    /// Spotify não aceita controle de fora: manda o app do Spotify no Mac tocar o link via Spotify Connect.
    /// Se a TV já for o dispositivo ativo do Spotify, já sai nela.
    private func openInSpotify(_ url: URL) {
        var uri = url.absoluteString
        let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        if url.host?.hasSuffix("spotify.com") == true, parts.count >= 2 { uri = "spotify:\(parts[0]):\(parts[1])" }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
            NSWorkspace.shared.open(url)
            notice = String(localized: "Abri no navegador. Instale o app do Spotify para transmitir para a TV.")
            return
        }
        let script = "tell application id \"com.spotify.client\" to play track \"\(uri)\""
        DispatchQueue.global().async { var e: NSDictionary?; _ = NSAppleScript(source: script)?.executeAndReturnError(&e) }
        notice = app?.appId == Self.spotifyApp
            ? String(localized: "Tocando no Spotify da TV.")
            : String(localized: "Tocando no Spotify. Se não sair na TV, no app do Spotify toque em “Conectar a um dispositivo” e escolha \(displayName) — é só uma vez.")
    }

    // MARK: Recentes

    private func remember(url: URL, title: String, kind: String, image: String?) {
        guard !isPreview else { return }
        let item = RecentCast(url: url.absoluteString, title: title, kind: kind, image: image, date: Date())
        recents.removeAll { $0.url == item.url }
        recents.insert(item, at: 0)
        recents = Array(recents.prefix(8))
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: "recents") }
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: "recents"),
              let list = try? JSONDecoder().decode([RecentCast].self, from: data) else { return }
        recents = list
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: "recents")
    }

    /// Arquivo do Mac: converte se a 1ª geração não suportar e serve pela rede local.
    private func castFile(_ url: URL) async {
        var file = url
        let plan = await Transcoder.plan(for: url)
        if plan != .direct {
            castProgress = plan == .remux ? String(localized: "Preparando vídeo…") : String(localized: "Convertendo para H.264…")
            do {
                file = try await Transcoder.export(url, plan: plan) { p in
                    Task { @MainActor [weak self] in
                        guard plan == .transcode else { return }
                        self?.castProgress = String(localized: "Convertendo \(Int(p * 100))%")
                    }
                }
            } catch {
                castProgress = nil
                self.error = String(localized: "Não consegui converter: \(error.localizedDescription)")
                return
            }
        }
        guard let host = channel?.localAddress, let port = try? MediaServer.shared.start() else {
            castProgress = nil
            error = String(localized: "Não consegui abrir o servidor local")
            return
        }
        let path = MediaServer.shared.publish(file: file)
        load(contentURL: "http://\(host):\(port)\(path)", mime: MediaServer.mime(for: file),
             title: url.deletingPathExtension().lastPathComponent)
    }

    /// Abre o app do YouTube no Chromecast e manda o vídeo pela Lounge API.
    func castYouTube(_ link: YouTubeLink, action: YouTubeLounge.Action = .playNow) {
        if dashboardOn { endDashboard() }
        // fila só faz sentido com o YouTube já aberto na TV; senão vira "tocar agora"
        let action = youtubeOnTV ? action : .playNow
        if action != .playNow, let screenId = youtubeScreenId {
            castProgress = action == .playNext ? String(localized: "Colocando a seguir…") : String(localized: "Adicionando à fila…")
            return sendLounge(action, link, screenId)
        }
        pendingYouTubeAction = action
        pendingYouTube = link
        youtubeTransportAsked = nil
        castProgress = String(localized: "Abrindo o YouTube…")
        if let a = app, a.appId == Self.youtubeApp, !a.transportId.isEmpty {
            youtubeTransportAsked = a.transportId
            send(to: a.transportId, ns: CastNS.connection, ["type": "CONNECT"])
            channel?.send(to: a.transportId, ns: CastNS.youtube, ["type": "getMdxSessionStatus"])
        } else {
            send(to: "receiver-0", ns: CastNS.receiver, ["type": "LAUNCH", "appId": Self.youtubeApp])
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            if self?.pendingYouTube == link {
                self?.pendingYouTube = nil
                self?.castProgress = nil
                self?.error = String(localized: "O YouTube não respondeu no Chromecast")
            }
        }
    }

    private func youtubeMessage(_ type: String, _ obj: [String: Any]) {
        guard type == "mdxSessionStatus",
              let screenId = (obj["data"] as? [String: Any])?["screenId"] as? String else { return }
        youtubeScreenId = screenId
        guard let link = pendingYouTube else { return }
        pendingYouTube = nil
        castProgress = String(localized: "Enviando o vídeo…")
        sendLounge(pendingYouTubeAction, link, screenId)
    }

    private func sendLounge(_ action: YouTubeLounge.Action, _ link: YouTubeLink, _ screenId: String) {
        Task {
            do {
                try await lounge.send(action, link: link, screenId: screenId, senderName: Host.current().localizedName ?? "Mac")
                castProgress = nil
                switch action {
                case .playNext: notice = String(localized: "Vai tocar a seguir na TV.")
                case .addToQueue: notice = String(localized: "Adicionado à fila da TV.")
                case .playNow: break
                }
            } catch {
                castProgress = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// Pula pro próximo da fila do YouTube.
    func youtubeNext() {
        guard let screenId = youtubeScreenId else { return }
        Task { try? await lounge.next(screenId: screenId) }
    }

    /// Abre o player padrão do Chromecast (se preciso) e manda carregar a mídia.
    private func load(contentURL: String, mime: String, title: String, image: URL? = nil, quiet: Bool = false, live: Bool = false,
                      fmp4: Bool = false) {
        let kind = mime.hasPrefix("image/") ? 4 : mime.hasPrefix("audio/") ? 3 : 0
        var metadata: [String: Any] = ["metadataType": kind, "title": title]
        if let image { metadata["images"] = [["url": image.absoluteString]] }
        var media: [String: Any] = [
            "contentId": contentURL,
            "contentType": mime,
            "streamType": live ? "LIVE" : "BUFFERED",
            "metadata": metadata,
        ]
        if fmp4 {
            // sem isso o player supõe segmentos MPEG-TS e trata os nossos fMP4 pelo caminho lento
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
        }
        let request: [String: Any] = ["type": "LOAD", "autoplay": true, "currentTime": 0, "media": media]
        if !quiet { castProgress = String(localized: "Abrindo na TV…") }
        if let a = app, a.appId == Self.defaultReceiver, a.hasMedia {
            send(to: a.transportId, ns: CastNS.media, request)
            castProgress = nil
        } else {
            pendingLoad = request
            send(to: "receiver-0", ns: CastNS.receiver, ["type": "LAUNCH", "appId": Self.defaultReceiver])
            Task { [weak self] in   // não deixa o aviso preso se o aparelho não responder
                try? await Task.sleep(for: .seconds(15))
                if self?.pendingLoad != nil { self?.pendingLoad = nil; self?.castProgress = nil }
            }
        }
    }

    // MARK: - Espelhar a tela

    /// Gravação de Tela liberada, mas o macOS só aplica depois que o app reabre.
    @Published private(set) var needsRelaunchForScreen = false

    /// Espelha a tela: primeiro o modo instantâneo (Cast Streaming, ~0,2 s); se o aparelho recusar, HLS (~4 s).
    func startMirroring() async {
        guard connected, !mirroring else { return }
        notice = nil
        // diagnóstico: CAST_TEST_PATTERN=1 troca a tela por um padrão animado (não precisa de permissão)
        let testPattern = ProcessInfo.processInfo.environment["CAST_TEST_PATTERN"] != nil
        guard testPattern || CGPreflightScreenCaptureAccess() else {
            log.notice("mirror: sem permissão de gravação de tela, pedindo")
            _ = CGRequestScreenCaptureAccess()
            needsRelaunchForScreen = true
            notice = String(localized: "Libere o app em Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela e Áudio do Sistema. Depois use “Reabrir app” — o macOS só aplica a permissão quando o app reabre.")
            return
        }
        needsRelaunchForScreen = false
        if dashboardOn { endDashboard() }
        let st = CastStreamer(profile: mirrorLowLatency ? .lowLatency : .smooth, withAudio: mirrorAudio)
        st.onError = { [weak self] message in
            Task { @MainActor in
                log.error("mirror: captura parou: \(message, privacy: .public)")
                self?.error = String(localized: "Espelhamento parou: \(message)")
                self?.stopMirroring()
            }
        }
        streamer = st
        streamerOffered = false
        mirroring = true
        mirrorInstant = true
        mirrorShown = false
        castProgress = String(localized: "Abrindo o espelhamento na TV…")
        log.notice("mirror: LAUNCH \(CastStreamer.receiverApp, privacy: .public)")
        send(to: "receiver-0", ns: CastNS.receiver, ["type": "LAUNCH", "appId": CastStreamer.receiverApp])
        // cada etapa tem prazo: nada de "carregando" pra sempre
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.mirroring, self.mirrorInstant, self.castProgress != nil else { return }
            log.error("mirror: sem resposta do receptor em 12 s (oferta enviada: \(self.streamerOffered))")
            self.fallbackToHLS()
        }
    }

    func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func streamingMessage(_ type: String, _ obj: [String: Any]) {
        guard type == "ANSWER", mirroring, mirrorInstant, let st = streamer else { return }
        let host = channel?.remoteAddress
            ?? UserDefaults.standard.string(forKey: "lastIP")?.split(separator: "%").first.map(String.init)
        log.notice("mirror: ANSWER result=\(obj["result"] as? String ?? "?", privacy: .public) host=\(host ?? "nil", privacy: .public)")
        guard obj["result"] as? String == "ok", let answer = obj["answer"] as? [String: Any],
              let port = answer["udpPort"] as? Int, let host else {
            return fallbackToHLS()
        }
        let audioOK = st.withAudio && ((answer["sendIndexes"] as? [Int])?.contains(1) ?? false)
        castProgress = String(localized: "Começando a enviar a tela…")
        Task {
            do {
                let pattern = ProcessInfo.processInfo.environment["CAST_TEST_PATTERN"] != nil
                try await withTimeout(seconds: 10) {
                    try await st.start(host: host, port: UInt16(port), audioAccepted: audioOK, testPattern: pattern)
                }
                log.notice("mirror: enviando para \(host, privacy: .public):\(port) áudio=\(audioOK)")
                mirrorHasAudio = audioOK
                if audioOK, muteMacWhileMirroring, !pattern { MacAudio.silence() }
                castProgress = nil
            } catch {
                log.error("mirror: captura não começou: \(error.localizedDescription, privacy: .public)")
                castProgress = nil
                stopMirroring()
                needsRelaunchForScreen = true
                notice = String(localized: "Não consegui capturar a tela. Se você acabou de liberar a Gravação de Tela, use “Reabrir app”.")
            }
        }
    }

    private func fallbackToHLS() {
        streamer?.stop(); streamer = nil
        mirroring = false
        mirrorInstant = false
        Task { await startHLSMirroring() }
    }

    /// Plano B: HLS ao vivo pelo player padrão (~4 s de atraso, mas funciona em qualquer receptor).
    private func startHLSMirroring() async {
        guard connected, !mirroring else { return }
        guard let host = channel?.localAddress, let port = try? MediaServer.shared.start() else {
            error = String(localized: "Não consegui abrir o servidor local"); return
        }
        let m = ScreenMirror()
        m.onReady = { [weak self] in
            Task { @MainActor in
                guard let self, self.mirroring else { return }
                self.load(contentURL: "http://\(host):\(port)\(m.playlistPath)", mime: "application/x-mpegurl",
                          title: Self.mirrorTitle, quiet: true, live: true, fmp4: true)
                self.castProgress = nil
            }
        }
        m.onError = { [weak self] message in
            Task { @MainActor in
                self?.error = String(localized: "Espelhamento parou: \(message)")
                self?.stopMirroring()
            }
        }
        mirror = m
        mirroring = true
        mirrorInstant = false
        mirrorShown = false
        castProgress = String(localized: "Preparando o espelhamento…")
        do {
            try await withTimeout(seconds: 10) { try await m.start(withAudio: self.mirrorAudio) }
        } catch {
            castProgress = nil
            endMirroring()
            notice = String(localized: "Não consegui capturar a tela. Confira a permissão de Gravação de Tela em Ajustes do Sistema.")
        }
    }

    func stopMirroring() {
        let showing = mirrorShown && (app?.appId == Self.defaultReceiver || app?.appId == CastStreamer.receiverApp)
        endMirroring()
        if showing { stopCasting() }
    }

    private func endMirroring() {
        mirror?.stop()
        mirror = nil
        streamer?.stop()
        streamer = nil
        streamerOffered = false
        mirrorHasAudio = false
        MacAudio.restore()
        mirroring = false
        mirrorShown = false
    }

    // MARK: - Painel da casa na TV

    /// Mostra relógio, data e clima na TV, atualizando a cada minuto.
    func startDashboard() {
        guard connected else { return }
        dashboardOn = true
        dashboardShown = false
        castProgress = String(localized: "Montando o painel…")
        dashboardTask?.cancel()
        dashboardTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pushDashboard()
                // acorda logo depois da virada do minuto, pro relógio da TV não atrasar
                let next = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 1
                try? await Task.sleep(for: .seconds(next))
            }
        }
    }

    func stopDashboard() {
        let wasShowing = dashboardShown && app?.appId == Self.defaultReceiver
        endDashboard()
        if wasShowing { stopCasting() }
    }

    private func endDashboard() {
        dashboardTask?.cancel(); dashboardTask = nil
        dashboardOn = false
        dashboardShown = false
    }

    private func pushDashboard() async {
        let w = await weather.current(timezone: info?.timezone ?? TimeZone.current.identifier)
        guard dashboardOn,
              let jpg = DashboardRenderer.png(now: Date(), weather: w, deviceName: displayName),
              let host = channel?.localAddress, let port = try? MediaServer.shared.start() else { return }
        MediaServer.shared.publish(data: jpg, path: "/dashboard.jpg", contentType: "image/jpeg")
        dashboardPreview = NSImage(data: jpg)
        load(contentURL: "http://\(host):\(port)/dashboard.jpg?t=\(Int(Date().timeIntervalSince1970))",
             mime: "image/jpeg", title: Self.dashboardTitle, quiet: dashboardShown)
    }

    /// Liga a TV e troca a entrada: abrir um app no Chromecast dispara o HDMI-CEC "One Touch Play".
    /// Abre o player padrão e fecha em seguida, voltando para a tela de fundo.
    func turnOnTV() {
        guard connected, !isCasting else { return }
        pendingTurnOn = true
        send(to: "receiver-0", ns: CastNS.receiver, ["type": "LAUNCH", "appId": Self.defaultReceiver])
        HUD.shared.show(symbol: "tv", title: String(localized: "Ligando a TV…"))
    }

    // MARK: - Timer de sono

    var sleepActive: Bool { sleepAt != nil }
    private let fadeDuration: TimeInterval = 60

    func startSleep(minutes: Int) {
        sleepMode = .duration
        sleepStart = Date()
        sleepAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        armSleep()
    }

    /// Para quando o que está tocando acabar (acompanha pausas).
    func sleepAtEndOfEpisode() {
        guard let m = media, let d = m.duration else { return }
        sleepMode = .endOfEpisode
        sleepStart = Date()
        sleepAt = Date().addingTimeInterval(max(d - m.position(at: Date()), 1))
        armSleep()
    }

    func extendSleep(minutes: Int) {
        guard let at = sleepAt else { return startSleep(minutes: minutes) }
        sleepMode = .duration
        sleepAt = max(at, Date()).addingTimeInterval(TimeInterval(minutes * 60))
        restoreFadedVolume()
    }

    func cancelSleep() {
        sleepTask?.cancel(); sleepTask = nil
        restoreFadedVolume()
        sleepAt = nil; sleepStart = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
    }

    private func armSleep() {
        sleepTask?.cancel()
        if sleepActivity == nil, !isPreview {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                   reason: "Timer de sono do Chromecast")
        }
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sleepTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func sleepTick() {
        guard var at = sleepAt else { return }
        // transmissão acabou por fora: não há o que desligar
        if connected, !isCasting { return cancelSleep() }
        if sleepMode == .endOfEpisode, let m = media, let d = m.duration {
            at = Date().addingTimeInterval(max(d - m.position(at: Date()), 0))   // pausado = o prazo anda junto
            sleepAt = at
        }
        let left = at.timeIntervalSinceNow
        if left <= 0 {
            fireSleep()
        } else if left <= fadeDuration {
            if volumeBeforeFade == nil { volumeBeforeFade = volume; fading = true }
            let target = (volumeBeforeFade ?? volume) * left / fadeDuration
            if abs(target - volume) >= 0.01 { setVolume(target) }
        }
    }

    private func fireSleep() {
        let original = volumeBeforeFade
        sleepTask?.cancel(); sleepTask = nil
        stopCasting()
        // devolve o volume original depois que o app fecha, pra próxima transmissão não começar muda
        if let original {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.setVolume(original)
            }
        }
        volumeBeforeFade = nil; fading = false
        sleepAt = nil; sleepStart = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
    }

    private func restoreFadedVolume() {
        if let v = volumeBeforeFade { setVolume(v) }
        volumeBeforeFade = nil
        fading = false
    }

    func sleepProgress(at now: Date) -> Double {
        guard let sleepAt, let sleepStart else { return 0 }
        let total = sleepAt.timeIntervalSince(sleepStart)
        return total > 0 ? min(max(now.timeIntervalSince(sleepStart) / total, 0), 1) : 1
    }

    // MARK: - API de configuração (canal setup)

    private func setup(_ route: String, _ data: [String: Any] = [:]) {
        channel?.send(to: "receiver-0", ns: CastNS.setup, ["type": route, "request_id": setupRequestId, "data": data])
        setupRequestId += 1
    }

    func requestDeviceInfo() { setup("eureka_info") }

    /// Muda o nome do aparelho (aparece no celular, no Chrome e aqui).
    func rename(to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        info?.name = name
        setup("set_eureka_info", ["name": name])
        Task { try? await Task.sleep(for: .seconds(1)); requestDeviceInfo() }
    }

    func reboot() {
        setup("reboot", ["params": "now"])
    }

    private func setupResponse(_ type: String, _ obj: [String: Any]) {
        let code = obj["response_code"] as? Int ?? 0
        guard code == 200 else {
            error = String(localized: "O Chromecast recusou \(type) (\(code))")
            return
        }
        if type == "eureka_info", let d = obj["data"] as? [String: Any] {
            info = DeviceInfo(name: d["name"] as? String ?? device?.name ?? "",
                              firmware: (d["cast_build_revision"] as? String) ?? "",
                              signal: d["signal_level"] as? Int,
                              ssid: d["ssid"] as? String,
                              timezone: d["timezone"] as? String)
        }
    }

    // MARK: - Cor da capa

    private func loadTint(for url: URL?) {
        guard url != lastArtwork else { return }
        lastArtwork = url
        guard let url else { artworkTint = nil; artworkImage = nil; return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            artworkImage = img
            publishNowPlaying()
            if let c = img.averageColor {
                withAnimation(.easeInOut(duration: 0.6)) { artworkTint = c }
            }
        }
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { String(localized: "Demorou demais para responder") }
}

/// Corre a operação contra um prazo.
func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimeoutError() }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

extension Notification.Name {
    /// Arquivos abertos pelo Finder ("Abrir com") para transmitir.
    static let castFiles = Notification.Name("castFiles")
}

extension NSImage {
    /// Cor média da imagem, clareada e saturada pra servir de tom da interface.
    var averageColor: Color? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return Color(hue: h, saturation: min(max(s * 1.3, 0.35), 0.85), brightness: max(b, 0.75))
    }
}
