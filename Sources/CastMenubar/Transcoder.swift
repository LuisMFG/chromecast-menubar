import AVFoundation
import Foundation

/// Prepara vídeos pra 1ª geração do Chromecast: só toca H.264 em MP4/WebM.
enum Transcoder {
    enum Plan { case direct, remux, transcode }

    /// H.264 em MP4 → direto; H.264 em MOV → só troca o contêiner; HEVC/ProRes/etc. → converte.
    static func plan(for url: URL) async -> Plan {
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let desc = try? await track.load(.formatDescriptions).first else {
            return .direct   // áudio, imagem ou contêiner que o AVFoundation não abre: tenta como está
        }
        let codec = CMFormatDescriptionGetMediaSubType(desc)
        let h264 = codec == kCMVideoCodecType_H264
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let tooBig = max(abs(size.width), abs(size.height)) > 1920
        if h264 && !tooBig { return ["mp4", "m4v"].contains(ext) ? .direct : .remux }
        return .transcode
    }

    /// Exporta para MP4 em uma pasta temporária, reportando progresso (0…1).
    static func export(_ url: URL, plan: Plan, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CastMenubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-cast.mp4")
        try? FileManager.default.removeItem(at: out)

        let preset = plan == .remux ? AVAssetExportPresetPassthrough : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: preset) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poll.cancel() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if let error = session.error { throw error }
        return out
    }
}
