import Foundation

/// Link do YouTube → vídeo, playlist e início.
struct YouTubeLink: Equatable {
    var videoId: String
    var listId: String = ""
    var start: Int = 0

    init?(_ url: URL) {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com") else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let parts = url.pathComponents.filter { $0 != "/" }
        var id: String?
        if host == "youtu.be" { id = parts.first }
        else if let v = q["v"] { id = v }
        else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) { id = parts[1] }
        guard let id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        videoId = id
        listId = q["list"] ?? ""
        start = Self.seconds(q["t"] ?? q["start"] ?? "")
    }

    /// "90", "90s", "1m30s", "1h2m3s"
    private static func seconds(_ t: String) -> Int {
        if let n = Int(t) { return n }
        var total = 0, num = 0
        for ch in t {
            if let d = ch.wholeNumberValue { num = num * 10 + d; continue }
            total += num * (ch == "h" ? 3600 : ch == "m" ? 60 : 1); num = 0
        }
        return total + num
    }
}

/// Lounge API do YouTube: é assim que o app do celular controla o YouTube do Chromecast.
/// screenId (pego no canal mdx do Cast) → loungeToken → bind (SID + gsessionid) → comandos.
/// A sessão fica aberta entre comandos (fila!) e é refeita sozinha quando expira.
/// Formato atual conferido com o pyytlounge; o do casttube (`req0__videoId`) é aceito mas ignorado.
actor YouTubeLounge {
    private let base = "https://www.youtube.com/api/lounge"
    private var screenId: String?
    private var token: String?
    private var sid: String?
    private var gsession: String?
    private var offset = 1
    private var senderName = "Mac"

    enum Failure: LocalizedError {
        case step(String)
        case sessionLost
        var errorDescription: String? {
            switch self {
            case .step(let s): return s
            case .sessionLost: return String(localized: "A sessão do YouTube expirou")
            }
        }
    }

    enum Action { case playNow, playNext, addToQueue }

    func send(_ action: Action, link: YouTubeLink, screenId: String, senderName: String) async throws {
        self.senderName = senderName
        var params = ["videoId": link.videoId]
        let command: String
        switch action {
        case .playNow:
            command = "setPlaylist"
            params["currentTime"] = "\(link.start)"
            params["currentIndex"] = "-1"
            if !link.listId.isEmpty { params["listId"] = link.listId }
        case .playNext: command = "insertVideo"
        case .addToQueue: command = "addVideo"
        }
        try await run(command, params, screenId: screenId)
    }

    func next(screenId: String) async throws { try await run("next", [:], screenId: screenId) }

    // MARK: - sessão

    private func run(_ command: String, _ params: [String: String], screenId: String) async throws {
        if screenId != self.screenId || sid == nil { try await connect(screenId) }
        do {
            try await self.command(command, params)
        } catch Failure.sessionLost {
            try await connect(screenId)          // SID venceu: refaz e repete uma vez
            try await self.command(command, params)
        }
    }

    private func connect(_ screenId: String) async throws {
        let (tokenBody, _) = try await post("\(base)/pairing/get_lounge_token_batch", form: ["screen_ids": screenId])
        guard let json = try? JSONSerialization.jsonObject(with: tokenBody) as? [String: Any],
              let token = (json["screens"] as? [[String: Any]])?.first?["loungeToken"] as? String else {
            throw Failure.step(String(localized: "YouTube recusou o pareamento"))
        }
        let form: [String: String] = [
            "app": "web", "mdx-version": "3", "name": senderName, "id": screenId,
            "device": "REMOTE_CONTROL", "capabilities": "que,dsdtr,atp,vsp", "magnaKey": "cloudPairedDevice",
            "ui": "false", "theme": "cl", "loungeIdToken": token,
            "deviceContext": "user_agent=dunno&window_width_points=&window_height_points=&os_name=android&ms=",
        ]
        let (data, _) = try await post("\(base)/bc/bind",
                                       query: ["RID": "1", "VER": "8", "CVER": "1", "auth_failure_option": "send_error"],
                                       form: form)
        let bind = String(decoding: data, as: UTF8.self)
        guard let sid = bind.firstMatch(#""c","(.*?)",""#), let gsession = bind.firstMatch(#""S","(.*?)"]"#) else {
            throw Failure.step(String(localized: "Não consegui abrir a sessão do YouTube"))
        }
        self.screenId = screenId
        self.token = token
        self.sid = sid
        self.gsession = gsession
        offset = 1
    }

    /// req0__sc = comando; parâmetros como req0_<nome>; ofs e RID avançam a cada comando.
    private func command(_ name: String, _ params: [String: String]) async throws {
        guard let token, let sid, let gsession else { throw Failure.sessionLost }
        var form = ["count": "1", "ofs": "\(offset)", "req0__sc": name]
        for (k, v) in params { form["req0_\(k)"] = v }
        offset += 1
        let (body, status) = try await post("\(base)/bc/bind",
                                            query: ["name": senderName, "loungeIdToken": token, "SID": sid, "AID": "0",
                                                    "gsessionid": gsession, "device": "REMOTE_CONTROL", "app": "youtube-desktop",
                                                    "VER": "8", "v": "2", "RID": "\(offset)"],
                                            form: form, allowFailure: true)
        if [400, 401, 404, 410].contains(status) {
            self.sid = nil
            throw Failure.sessionLost
        }
        if status != 200 {
            throw Failure.step(String(localized: "YouTube respondeu HTTP \(status): \(String(decoding: body.prefix(80), as: UTF8.self))"))
        }
    }

    private func post(_ url: String, query: [String: String] = [:], form: [String: String],
                      allowFailure: Bool = false) async throws -> (Data, Int) {
        var comps = URLComponents(string: url)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Origin")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !allowFailure, status != 200 {
            throw Failure.step(String(localized: "YouTube respondeu HTTP \(status)"))
        }
        return (data, status)
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
