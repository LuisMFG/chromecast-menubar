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

/// Lounge API do YouTube: é assim que o app do celular manda vídeos pro YouTube do Chromecast.
/// screenId (pego no canal mdx do Cast) → loungeToken → bind (SID + gsessionid) → setPlaylist.
/// Formato atual conferido com o pyytlounge; o do casttube (`req0__videoId`) é aceito mas ignorado.
actor YouTubeLounge {
    private let base = "https://www.youtube.com/api/lounge"

    enum Failure: LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    func play(screenId: String, link: YouTubeLink, senderName: String) async throws {
        // 1. token
        let tokenBody = try await post("\(base)/pairing/get_lounge_token_batch", form: ["screen_ids": screenId])
        guard let json = try? JSONSerialization.jsonObject(with: tokenBody) as? [String: Any],
              let token = (json["screens"] as? [[String: Any]])?.first?["loungeToken"] as? String else {
            throw Failure.step(String(localized: "YouTube recusou o pareamento"))
        }
        // 2. bind (formato atual da Lounge API, como no pyytlounge)
        let bindForm: [String: String] = [
            "app": "web", "mdx-version": "3", "name": senderName, "id": screenId,
            "device": "REMOTE_CONTROL", "capabilities": "que,dsdtr,atp,vsp", "magnaKey": "cloudPairedDevice",
            "ui": "false", "theme": "cl", "loungeIdToken": token,
            "deviceContext": "user_agent=dunno&window_width_points=&window_height_points=&os_name=android&ms=",
        ]
        let bind = String(decoding: try await post("\(base)/bc/bind",
                                                   query: ["RID": "1", "VER": "8", "CVER": "1", "auth_failure_option": "send_error"],
                                                   form: bindForm), as: UTF8.self)
        guard let sid = bind.firstMatch(#""c","(.*?)",""#), let gsession = bind.firstMatch(#""S","(.*?)"]"#) else {
            throw Failure.step(String(localized: "Não consegui abrir a sessão do YouTube"))
        }
        // 3. tocar: req0__sc = comando; parâmetros como req0_<nome>
        var form = ["count": "1", "ofs": "1", "req0__sc": "setPlaylist", "req0_videoId": link.videoId,
                    "req0_currentTime": "\(link.start)", "req0_currentIndex": "-1"]
        if !link.listId.isEmpty { form["req0_listId"] = link.listId }
        _ = try await post("\(base)/bc/bind",
                           query: ["name": senderName, "loungeIdToken": token, "SID": sid, "AID": "0", "gsessionid": gsession,
                                   "device": "REMOTE_CONTROL", "app": "youtube-desktop", "VER": "8", "v": "2", "RID": "2"],
                           form: form)
    }

    private func post(_ url: String, query: [String: String] = [:], form: [String: String]) async throws -> Data {
        var comps = URLComponents(string: url)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Origin")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.step(String(localized: "YouTube respondeu HTTP \(http.statusCode)"))
        }
        return data
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
