import AppKit
import Foundation

/// O que fazer com um link: cada serviço tem um caminho diferente até a TV.
enum CastTarget {
    case youtube(YouTubeLink)
    case media(url: URL, mime: String, title: String, image: URL?)
    case spotify(URL)
    case unsupported(String)
}

enum Resolver {
    static let drm = ["netflix.com": "Netflix", "primevideo.com": "Prime Video", "disneyplus.com": "Disney+",
                      "max.com": "Max", "globoplay.globo.com": "Globoplay", "tv.apple.com": "Apple TV+",
                      "paramountplus.com": "Paramount+", "crunchyroll.com": "Crunchyroll"]

    /// Sites que costumam exigir login (yt-dlp usa a sessão do navegador se o usuário permitir).
    static let loginSites = ["instagram.com", "x.com", "twitter.com"]

    static func resolve(_ url: URL, cookiesFrom browser: String? = nil) async -> CastTarget {
        let host = url.host?.lowercased() ?? ""
        if url.isFileURL { return .media(url: url, mime: MediaServer.mime(for: url), title: url.deletingPathExtension().lastPathComponent, image: nil) }
        if let yt = YouTubeLink(url) { return .youtube(yt) }
        if host.hasSuffix("spotify.com") || url.scheme == "spotify" { return .spotify(url) }
        if let name = drm.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value {
            return .unsupported(String(localized: "\(name) usa proteção contra cópia (DRM) e só transmite pelo app oficial no celular."))
        }
        // link direto pra arquivo
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "webm", "mp3", "m4a", "aac", "wav", "ogg", "flac", "jpg", "jpeg", "png", "gif", "webp", "m3u8"].contains(ext) {
            return .media(url: url, mime: MediaServer.mime(for: url), title: url.deletingPathExtension().lastPathComponent, image: nil)
        }
        // pergunta o tipo pro servidor
        if let type = await contentType(of: url), type.hasPrefix("video/") || type.hasPrefix("audio/") || type.hasPrefix("image/") || type.contains("mpegurl") {
            return .media(url: url, mime: type, title: url.lastPathComponent, image: nil)
        }
        // página: procura vídeo nas metatags (og:video, twitter:player:stream, <video src>)
        let social = loginSites.contains { host == $0 || host.hasSuffix("." + $0) }
        if !social, let found = await pageMedia(url) { return found }
        // yt-dlp, se instalado, cobre centenas de sites (Twitch, X, Instagram, Vimeo, SoundCloud…)
        if let found = await ytdlp(url, cookiesFrom: browser) { return found }
        return .unsupported(YTDLP.path == nil
            ? String(localized: "Não achei vídeo nessa página. Com o yt-dlp instalado, centenas de sites passam a funcionar.")
            : String(localized: "Não achei vídeo compatível nessa página."))
    }

    private static func contentType(of url: URL) async -> String? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            .components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
    }

    private static func pageMedia(_ url: URL) async -> CastTarget? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let html = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        func meta(_ name: String) -> String? {
            for pattern in [#"<meta[^>]+(?:property|name)=["']\#(name)["'][^>]+content=["']([^"']+)["']"#,
                            #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']\#(name)["']"#] {
                if let m = html.firstCapture(pattern) { return m.replacingOccurrences(of: "&amp;", with: "&") }
            }
            return nil
        }
        let title = meta("og:title") ?? html.firstCapture(#"<title[^>]*>([^<]+)</title>"#) ?? url.host ?? ""
        let image = meta("og:image").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        let candidates = [meta("og:video:secure_url"), meta("og:video:url"), meta("og:video"), meta("twitter:player:stream"),
                          html.firstCapture(#"<video[^>]+src=["']([^"']+)["']"#),
                          html.firstCapture(#"<source[^>]+src=["']([^"']+\.(?:mp4|webm|m3u8)[^"']*)["']"#),
                          meta("og:audio")].compactMap { $0 }
        for c in candidates {
            guard let u = URL(string: c, relativeTo: url)?.absoluteURL, u.scheme?.hasPrefix("http") == true else { continue }
            let ext = u.pathExtension.lowercased()
            // og:video às vezes aponta pra um player embutido (html), não pro arquivo
            var isMedia = ["mp4", "webm", "m3u8", "mp3", "m4a"].contains(ext)
            if !isMedia { isMedia = (await contentType(of: u))?.hasPrefix("video/") == true }
            if isMedia {
                return .media(url: u, mime: MediaServer.mime(for: u), title: title.htmlDecoded, image: image)
            }
        }
        return nil
    }

    private static func ytdlp(_ url: URL, cookiesFrom browser: String?) async -> CastTarget? {
        guard let path = YTDLP.path else { return nil }
        let host = url.host?.lowercased() ?? ""
        let needsLogin = loginSites.contains { host == $0 || host.hasSuffix("." + $0) }
        var arguments = args(for: url)
        if needsLogin, let browser { arguments.insert(contentsOf: ["--cookies-from-browser", browser], at: 0) }
        let (out, failure) = await run(path, arguments, timeout: 45)
        if let failure {
            let loginProblem = ["login", "cookies", "empty media", "rate-limit", "not available"].contains { failure.lowercased().contains($0) }
            if needsLogin, loginProblem {
                return .unsupported(browser == nil
                    ? String(localized: "Esse post pede login. Ative ⋯ → “Usar login do navegador” para o app usar a sua sessão do Instagram/X.")
                    : String(localized: "Mesmo com o login do navegador o post não abriu — confira se ele abre no navegador."))
            }
            return .unsupported(String(localized: "O yt-dlp não conseguiu ler este site: \(failure.prefix(140)). Às vezes resolve atualizando: brew upgrade yt-dlp"))
        }
        guard let out,
              let j = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
              let media = (j["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let isAudio = (j["vcodec"] as? String) == "none"
        let isHLS = (j["protocol"] as? String)?.contains("m3u8") == true
        let mime = isHLS ? "application/x-mpegurl" : isAudio ? "audio/mp4" : "video/mp4"
        return .media(url: media, mime: mime, title: j["title"] as? String ?? url.host ?? "",
                      image: (j["thumbnail"] as? String).flatMap(URL.init(string:)))
    }

    private static func args(for url: URL) -> [String] {
        // a 1ª geração só toca H.264 até 1080p; prefere arquivo único (sem juntar áudio/vídeo)
        ["-j", "--no-playlist", "--no-warnings",
         "-f", "best[ext=mp4][vcodec^=avc1][height<=1080]/best[ext=mp4][height<=1080]/best[protocol^=m3u8][height<=1080]/best[height<=1080]/best",
         url.absoluteString]
    }

    /// Roda o yt-dlp; devolve a saída ou a última linha "ERROR:" dele.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (Data?, String?) {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { c.resume(returning: (nil, nil)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                let lastError = errText.split(separator: "\n").last { $0.hasPrefix("ERROR:") }
                    .map { $0.replacingOccurrences(of: "ERROR: ", with: "").replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression) }
                c.resume(returning: p.terminationStatus == 0 ? (data, nil) : (nil, lastError ?? "falhou"))
            }
        }
    }
}

enum YTDLP {
    static var path: String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension String {
    func firstCapture(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
    var htmlDecoded: String {
        var s = self
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&lt;": "<", "&gt;": ">"] { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}

/// Últimas coisas transmitidas, pra repetir com um clique.
struct RecentCast: Codable, Equatable, Identifiable {
    var id: String { url }
    var url: String
    var title: String
    var kind: String        // youtube, media, file
    var image: String?
    var date: Date
}
