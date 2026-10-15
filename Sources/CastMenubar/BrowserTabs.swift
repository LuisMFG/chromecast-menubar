import AppKit

/// Aba ativa do navegador usado por último (Brave, Chrome, Arc, Edge, Safari…), via AppleScript.
struct BrowserTab: Equatable {
    var browser: String
    var bundleId: String
    var title: String
    var url: URL
}

@MainActor
final class BrowserWatcher {
    static let browsers: [String: String] = [
        "com.brave.Browser": "Brave",
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.apple.Safari": "Safari",
    ]
    private(set) var lastBrowser: String?
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.browsers[front] != nil {
            lastBrowser = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, Self.browsers[id] != nil else { return }
            Task { @MainActor in self?.lastBrowser = id }
        }
    }

    /// Nome que o yt-dlp entende para `--cookies-from-browser` (Arc não é suportado: usa o Chrome).
    var ytdlpBrowserName: String {
        switch lastBrowser {
        case "com.apple.Safari": "safari"
        case "com.google.Chrome", "company.thebrowser.Browser": "chrome"
        case "com.microsoft.edgemac": "edge"
        case "com.vivaldi.Vivaldi": "vivaldi"
        default: "brave"
        }
    }

    /// Lê a aba ativa. Na primeira vez o macOS pergunta se o app pode controlar o navegador.
    func activeTab() async -> BrowserTab? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = ([lastBrowser].compactMap { $0 } + Self.browsers.keys.sorted()).filter { running.contains($0) }
        for id in candidates {
            if let tab = await Self.query(id) { lastBrowser = id; return tab }
        }
        return nil
    }

    private static func query(_ bundleId: String) async -> BrowserTab? {
        let safari = bundleId == "com.apple.Safari"
        let source = safari
            ? "tell application id \"\(bundleId)\" to if (count of windows) > 0 then return (URL of current tab of front window) & \"\\n\" & (name of current tab of front window)"
            : "tell application id \"\(bundleId)\" to if (count of windows) > 0 then return (URL of active tab of front window) & \"\\n\" & (title of active tab of front window)"
        let result: String? = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
                c.resume(returning: out)
            }
        }
        guard let result else { return nil }
        let parts = result.split(separator: "\n", maxSplits: 1).map(String.init)
        guard let first = parts.first, let url = URL(string: first), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return BrowserTab(browser: browsers[bundleId] ?? "Navegador", bundleId: bundleId,
                          title: parts.count > 1 ? parts[1] : url.host ?? first, url: url)
    }

    /// Pausa o vídeo da aba (só funciona se o navegador permitir JavaScript via Apple Events; falha em silêncio).
    static func pauseVideo(in tab: BrowserTab) {
        guard tab.bundleId != "com.apple.Safari" else { return }
        let js = "document.querySelectorAll('video,audio').forEach(function(v){v.pause()})"
        let source = "tell application id \"\(tab.bundleId)\" to execute active tab of front window javascript \"\(js)\""
        DispatchQueue.global().async { var e: NSDictionary?; _ = NSAppleScript(source: source)?.executeAndReturnError(&e) }
    }
}
