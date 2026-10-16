import AppKit
import Foundation

/// O que está tocando no Stremio (stream de torrent servido pelo servidor local dele).
struct StremioNow: Equatable {
    var infoHash: String
    var fileIndex: Int
    var title: String
}

/// Integração com o servidor de streaming do Stremio (mapeado com REA a partir do server.js do app):
/// - `GET /stats.json` lista os torrents ativos; `/<infoHash>/<idx>/stats.json` dá o `streamProgress` de cada arquivo;
/// - `GET /hlsv2/<sessão>/master.m3u8?mediaURL=…&videoCodecs=h264&audioCodecs=aac&maxAudioChannels=2&maxWidth=…`
///   converte qualquer fonte (MKV, HEVC, AC3…) em HLS fMP4 que a 1ª geração toca, com o ffmpeg embutido;
/// - o servidor escuta em todas as interfaces (porta 11470…11474) e manda CORS `*` no /hlsv2.
enum StremioBridge {
    static let bundleId = "com.westbridge.stremio5-mac"
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "wmv", "ts", "m2ts", "flv", "mpg", "mpeg"]

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// Porta em que o servidor respondeu (ele tenta 11470 e sobe até 11474 se estiver ocupada).
    static func serverPort() async -> Int? {
        for port in 11470...11474 {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/settings")!, timeoutInterval: 1.5)
            req.httpMethod = "GET"
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                return port
            }
        }
        return nil
    }

    /// Descobre o que está tocando: o torrent mais ativo e, dentro dele, o arquivo de vídeo com mais streamProgress.
    static func nowPlaying(port: Int) async -> StremioNow? {
        guard let stats = await json("http://127.0.0.1:\(port)/stats.json") as? [String: Any] else { return nil }
        let engines = stats.compactMap { key, value -> [String: Any]? in
            key == "sys" ? nil : value as? [String: Any]
        }
        // mais ativo primeiro: baixando agora > com pares > o resto
        let ranked = engines.sorted {
            let a = ($0["downloadSpeed"] as? Double ?? 0, $0["peers"] as? Int ?? 0)
            let b = ($1["downloadSpeed"] as? Double ?? 0, $1["peers"] as? Int ?? 0)
            return a > b
        }
        for e in ranked {
            guard let hash = e["infoHash"] as? String, let files = e["files"] as? [[String: Any]] else { continue }
            let videos = files.enumerated().filter { _, f in
                videoExtensions.contains(((f["name"] as? String ?? "") as NSString).pathExtension.lowercased())
            }
            guard !videos.isEmpty else { continue }
            var best = videos.max { ($0.element["length"] as? Double ?? 0) < ($1.element["length"] as? Double ?? 0) }!
            if videos.count > 1 {   // pacote de episódios: o que está sendo baixado pra tocar
                var top = -1.0
                for v in videos {
                    let s = await json("http://127.0.0.1:\(port)/\(hash)/\(v.offset)/stats.json") as? [String: Any]
                    let p = s?["streamProgress"] as? Double ?? 0
                    if p > top { top = p; best = v }
                }
            }
            let name = (best.element["name"] as? String) ?? (e["name"] as? String) ?? "Stremio"
            return StremioNow(infoHash: hash, fileIndex: best.offset, title: cleanTitle(name))
        }
        return nil
    }

    /// URL que a TV abre: HLS convertido pelo Stremio a partir de `mediaURL`.
    static func hlsURL(host: String, port: Int, mediaURL: String, maxWidth: Int = 1920) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let media = mediaURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? mediaURL
        let session = "cast\(UInt32.random(in: 1...UInt32.max))"
        return "http://\(host):\(port)/hlsv2/\(session)/master.m3u8?mediaURL=\(media)"
            + "&videoCodecs=h264&audioCodecs=aac&maxAudioChannels=2&maxWidth=\(maxWidth)"
    }

    /// "Movie.Name.2024.1080p.WEB-DL.x265-GRP.mkv" → "Movie Name 2024"
    static func cleanTitle(_ raw: String) -> String {
        var t = (raw as NSString).deletingPathExtension
        t = t.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        if let r = t.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            t = String(t[..<r.upperBound])          // corta depois do ano
        } else if let r = t.range(of: #"\b(2160p|1080p|720p|480p|WEB|BluRay|BRRip|HDTV|x26[45]|HEVC)\b"#,
                                     options: [.regularExpression, .caseInsensitive]) {
            t = String(t[..<r.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-[](")))
    }

    private static func json(_ url: String) async -> Any? {
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 3)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
