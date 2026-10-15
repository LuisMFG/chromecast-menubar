import Foundation
import Network
import UniformTypeIdentifiers

/// Servidor HTTP mínimo pra entregar arquivos locais ao Chromecast (com Range, pra permitir pular).
final class MediaServer: @unchecked Sendable {
    static let shared = MediaServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "media.server")
    private var files: [String: URL] = [:]
    private var blobs: [String: (Data, String)] = [:]
    private(set) var port: UInt16 = 0

    /// Inicia (uma vez) e devolve a porta.
    func start() throws -> UInt16 {
        if let listener, listener.state == .ready { return port }
        let l = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = l.port?.rawValue ?? 0; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        listener = l
        _ = ready.wait(timeout: .now() + 3)
        guard port != 0 else { throw URLError(.cannotConnectToHost) }
        return port
    }

    /// Publica um arquivo e devolve o caminho (com token, pra não expor o disco).
    func publish(file: URL) -> String {
        let token = UUID().uuidString.prefix(12).lowercased()
        let path = "/f/\(token)/" + (file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media")
        queue.sync { files[path] = file }
        return path
    }

    /// Publica bytes em memória num caminho fixo (substitui o anterior).
    func publish(data: Data, path: String, contentType: String) {
        queue.sync { blobs[path] = (data, contentType) }
    }

    // MARK: - HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return self.reply(c, 400, [:], Data()) }
            let method = String(parts[0])
            let path = String(parts[1]).components(separatedBy: "?")[0]
            let range = lines.first { $0.lowercased().hasPrefix("range:") }

            if let (blob, type) = self.blobs[path] {
                return self.reply(c, 200, ["Content-Type": type, "Cache-Control": "no-store"], method == "HEAD" ? Data() : blob,
                                  length: blob.count)
            }
            guard let file = self.files[path],
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue,
                  let fh = try? FileHandle(forReadingFrom: file) else {
                return self.reply(c, 404, [:], Data())
            }
            var start = 0, end = size - 1, status = 200
            if let range, let spec = range.split(separator: "=").last {
                let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let s = Int(bounds.first ?? "") { start = s }
                if bounds.count > 1, let e = Int(bounds[1]) { end = min(e, size - 1) }
                status = 206
            }
            guard start <= end else { return self.reply(c, 416, ["Content-Range": "bytes */\(size)"], Data()) }
            var headers = ["Content-Type": Self.mime(for: file), "Accept-Ranges": "bytes",
                           "Access-Control-Allow-Origin": "*"]
            if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
            let length = end - start + 1
            self.reply(c, status, headers, Data(), length: length, keepOpen: method != "HEAD")
            guard method != "HEAD" else { return }
            try? fh.seek(toOffset: UInt64(start))
            self.stream(fh, remaining: length, to: c)
        }
    }

    private func stream(_ fh: FileHandle, remaining: Int, to c: NWConnection) {
        guard remaining > 0 else { try? fh.close(); c.send(content: nil, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let chunk = fh.readData(ofLength: min(remaining, 256 * 1024))
        guard !chunk.isEmpty else { try? fh.close(); c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? fh.close(); c.cancel(); return }
            self?.stream(fh, remaining: remaining - chunk.count, to: c)
        })
    }

    private func reply(_ c: NWConnection, _ status: Int, _ headers: [String: String], _ body: Data,
                       length: Int? = nil, keepOpen: Bool = false) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 416: "Range Not Satisfiable"][status] ?? "OK"
        var h = "HTTP/1.1 \(status) \(reason)\r\n"
        var all = headers
        all["Content-Length"] = "\(length ?? body.count)"
        all["Connection"] = "close"
        for (k, v) in all { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in if !keepOpen { c.cancel() } })
    }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "m3u8": return "application/x-mpegurl"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
        }
    }
}
