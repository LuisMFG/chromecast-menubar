import AppKit
import Foundation
import Network
import SwiftUI
import Carbon.HIToolbox

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
    @Published private(set) var dashboardOn = false
    @Published private(set) var dashboardPreview: NSImage?

    private var browser: NWBrowser?
    private var channel: CastChannel?
    private var mediaTransport: String?
    private var requestId = 1
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
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
    private var pendingYouTube: YouTubeLink?
    private var youtubeTransportAsked: String?
    private let lounge = YouTubeLounge()

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
        NotificationCenter.default.addObserver(forName: .castFiles, object: nil, queue: .main) { [weak self] n in
            guard let urls = n.object as? [URL], let url = urls.first else { return }
            Task { @MainActor in await self?.cast(url) }
        }
    }

    /// Store com dados fictícios, usado só pra gerar snapshots da interface.
    init(preview app: ReceiverApp?, media: MediaState?, volume: Double, tint: Color? = nil) {
        devices = [CastDevice(id: "preview", name: "Sala", model: "Chromecast", endpoint: .hostPort(host: "127.0.0.1", port: 8009))]
        selectedId = "preview"
        connected = true
        self.app = app
        self.media = media
        self.volume = volume
        self.artworkTint = tint
        isPreview = true
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
        devices = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedId == nil || !devices.contains(where: { $0.id == selectedId }) {
            let saved = UserDefaults.standard.string(forKey: "device")
            selectedId = devices.first { $0.id == saved }?.id ?? devices.first?.id
        }
    }

    // MARK: - Conexão

    func connect() {
        reconnectTask?.cancel()
        pollTask?.cancel()
        channel?.stop()
        channel = nil
        mediaTransport = nil
        connected = false
        guard let device else { return }
        UserDefaults.standard.set(device.id, forKey: "device")

        let ch = CastChannel(endpoint: device.endpoint)
        ch.onMessage = { [weak self] msg in Task { @MainActor in self?.handle(msg) } }
        ch.onState = { [weak self] state in Task { @MainActor in self?.channelState(state) } }
        ch.start()
        channel = ch
    }

    private func channelState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connected = true
            error = nil
            requestStatus()
            requestDeviceInfo()
            startPolling()
        case .failed(let e):
            connected = false
            error = e.localizedDescription
            scheduleReconnect()
        case .cancelled:
            connected = false
            scheduleReconnect()
        case .waiting(let e):
            connected = false
            error = e.localizedDescription
            scheduleReconnect()
        default: break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
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

    /// Arquivo local ou link http(s). Vídeos fora do padrão da 1ª geração são convertidos antes.
    func cast(_ url: URL) async {
        guard connected else { error = String(localized: "Chromecast desconectado"); return }
        if let yt = YouTubeLink(url) { return castYouTube(yt) }
        if !url.isFileURL {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            return load(contentURL: url.absoluteString, mime: MediaServer.mime(for: url), title: url.lastPathComponent)
        }
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
    func castYouTube(_ link: YouTubeLink) {
        if dashboardOn { endDashboard() }
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
        guard type == "mdxSessionStatus", let link = pendingYouTube,
              let screenId = (obj["data"] as? [String: Any])?["screenId"] as? String else { return }
        pendingYouTube = nil
        castProgress = String(localized: "Enviando o vídeo…")
        Task {
            do {
                try await lounge.play(screenId: screenId, link: link, senderName: Host.current().localizedName ?? "Mac")
                castProgress = nil
            } catch {
                castProgress = nil
                self.error = error.localizedDescription
            }
        }
    }

    /// Abre o player padrão do Chromecast (se preciso) e manda carregar a mídia.
    private func load(contentURL: String, mime: String, title: String, quiet: Bool = false) {
        let kind = mime.hasPrefix("image/") ? 4 : mime.hasPrefix("audio/") ? 3 : 0
        let request: [String: Any] = [
            "type": "LOAD",
            "autoplay": true,
            "currentTime": 0,
            "media": [
                "contentId": contentURL,
                "contentType": mime,
                "streamType": "BUFFERED",
                "metadata": ["metadataType": kind, "title": title],
            ],
        ]
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
