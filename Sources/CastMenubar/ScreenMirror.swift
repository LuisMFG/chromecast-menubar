import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Espelha a tela do Mac como HLS ao vivo: ScreenCaptureKit → AVAssetWriter (H.264 + AAC em segmentos
/// fMP4 de 1 s, nativo do macOS) → servidor local → Default Media Receiver do Chromecast.
final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate, AVAssetWriterDelegate, @unchecked Sendable {
    static let prefix = "/mirror"
    var playlistPath: String { Self.prefix + "/live.m3u8" }

    /// Chamado (na fila interna) quando já há segmentos suficientes pra TV começar.
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "screen.mirror")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    private var started = false
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.invalid
    private var format: CMVideoFormatDescription?
    private var repeater: DispatchSourceTimer?
    private var segments: [(name: String, duration: Double)] = []
    private var sequence = 0
    private var readyFired = false
    private let width: Int
    private let height: Int
    /// Segmentos de 2 s: com 1 s a 1ª geração alcança o "ao vivo" e fica parando pra carregar.
    let segmentSeconds: Double
    /// Quantos segmentos esperar antes de mandar a TV tocar (folga contra engasgos).
    let startAfter: Int

    let bitrate: Int
    let fps: Int

    init(maxWidth: Int = 1280, segmentSeconds: Double = 2, startAfter: Int = 3, bitrate: Int = 3_500_000, fps: Int = 30) {
        self.bitrate = bitrate
        self.fps = fps
        self.segmentSeconds = segmentSeconds
        self.startAfter = startAfter
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let w = min(maxWidth, Int(screen.width))
        width = w / 2 * 2
        height = Int(Double(w) * screen.height / screen.width) / 2 * 2
    }

    func start(withAudio: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.capturesAudio = withAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if withAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
        setupWriter(withAudio: withAudio)
        startRepeater()
    }

    /// Padrão de teste animado no lugar da tela (valida o caminho HLS → TV sem permissão de gravação).
    func startTestPattern() {
        setupWriter(withAudio: false)
        let t = DispatchSource.makeTimerSource(queue: queue)
        var n = 0
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in
            guard let self, let writer = self.writer else { return }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, self.width, self.height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb)
            let bar = (n * 12) % self.width
            for y in 0..<self.height {
                for x in 0..<self.width {
                    let p = base + y * row + x * 4
                    let onBar = abs(x - bar) < 24
                    p[0] = onBar ? 255 : UInt8(x * 255 / self.width)
                    p[1] = onBar ? 255 : UInt8(y * 255 / self.height)
                    p[2] = onBar ? 255 : UInt8((n * 4) % 255)
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            var fmt: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
            self.format = fmt
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            if !self.started {
                writer.initialSegmentStartTime = pts
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
                self.started = true
            }
            self.appendVideo(pb, at: pts)
            n += 1
        }
        t.resume()
        repeater = t
    }

    func stop() {
        repeater?.cancel(); repeater = nil
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async {
            self.video?.markAsFinished(); self.audio?.markAsFinished()
            self.writer?.cancelWriting()
            self.writer = nil
            for seg in self.segments { MediaServer.shared.unpublish(path: Self.prefix + "/" + seg.name) }
            MediaServer.shared.unpublish(path: Self.prefix + "/init.mp4")
            MediaServer.shared.unpublish(path: self.playlistPath)
            self.segments.removeAll()
        }
    }

    // MARK: - Writer (HLS fMP4)

    private func setupWriter(withAudio: Bool) {
        let w = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 600)
        w.delegate = self
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,   // a 1ª geração decodifica sem esforço
                AVVideoMaxKeyFrameIntervalKey: Int(Double(fps) * segmentSeconds),  // 1 keyframe por segmento
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        w.add(v)
        video = v
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            w.add(a)
            audio = a
        }
        writer = w
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer else { return }
        switch type {
        case .screen:
            // quadros "idle" (tela parada) não têm imagem: o repetidor cobre
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = sb.imageBuffer else { return }
            let pts = sb.presentationTimeStamp
            if !started {
                writer.initialSegmentStartTime = pts
                guard writer.startWriting() else { onError?(writer.error?.localizedDescription ?? "writer"); return }
                writer.startSession(atSourceTime: pts)
                started = true
            }
            lastFrame = pb
            format = sb.formatDescription
            appendVideo(pb, at: pts)
        case .audio:
            guard started, let audio, audio.isReadyForMoreMediaData else { return }
            audio.append(sb)
        default: break
        }
    }

    private func appendVideo(_ pb: CVPixelBuffer, at pts: CMTime) {
        guard let video, video.isReadyForMoreMediaData, let format,
              !lastFrameTime.isValid || pts > lastFrameTime else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        if let out, video.append(out) { lastFrameTime = pts }
    }

    /// Tela parada não gera quadros; sem quadros o HLS trava. Repete o último a 10 fps quando precisa.
    private func startRepeater() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, self.started, let pb = self.lastFrame else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if !self.lastFrameTime.isValid || (now - self.lastFrameTime).seconds > 0.09 {
                self.appendVideo(pb, at: now)
            }
        }
        t.resume()
        repeater = t
    }

    // MARK: - Segmentos → playlist

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        queue.async { self.handleSegment(data, segmentType, segmentReport) }
    }

    private func handleSegment(_ data: Data, _ type: AVAssetSegmentType, _ report: AVAssetSegmentReport?) {
        switch type {
        case .initialization:
            MediaServer.shared.publish(data: data, path: Self.prefix + "/init.mp4", contentType: "video/mp4")
        case .separable:
            sequence += 1
            let name = "seg\(sequence).m4s"
            MediaServer.shared.publish(data: data, path: Self.prefix + "/" + name, contentType: "video/iso.segment")
            let duration = report?.trackReports.first?.duration.seconds ?? 1
            segments.append((name, duration))
            while segments.count > 10 {   // janela deslizante: libera memória dos antigos
                MediaServer.shared.unpublish(path: Self.prefix + "/" + segments.removeFirst().name)
            }
            publishPlaylist()
            if ProcessInfo.processInfo.environment["MIRROR_DEBUG"] != nil { print(String(format: "segmento %@ %.2fs", name, duration)) }
            if !readyFired, segments.count >= startAfter { readyFired = true; onReady?() }
        @unknown default: break
        }
    }

    private func publishPlaylist() {
        let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
        var m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(max(target, 1))
        #EXT-X-MEDIA-SEQUENCE:\(sequence - segments.count + 1)
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"

        """
        for seg in segments { m3u8 += String(format: "#EXTINF:%.3f,\n%@\n", seg.duration, seg.name) }
        MediaServer.shared.publish(data: Data(m3u8.utf8), path: playlistPath, contentType: "application/vnd.apple.mpegurl")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }
}
