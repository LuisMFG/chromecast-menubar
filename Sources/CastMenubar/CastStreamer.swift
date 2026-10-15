import AudioToolbox
import AVFoundation
import CommonCrypto
import CoreMedia
import Foundation
import Network
import os
import ScreenCaptureKit
import VideoToolbox

/// Espelhamento instantâneo pelo Cast Streaming — o mesmo protocolo do "transmitir aba" do Chrome.
///
/// 1. Abre o receptor de espelhamento (0F5096E8) e manda um OFFER em `urn:x-cast:com.google.cast.webrtc`.
/// 2. O ANSWER traz a porta UDP do aparelho.
/// 3. Vídeo H.264 (Annex B) e áudio Opus (20 ms) viram quadros criptografados com AES-128-CTR e vão em pacotes
///    RTP com o cabeçalho Cast — um fluxo (SSRC, chave, numeração) para cada.
/// 4. RTCP: Sender Report de cada fluxo a cada 500 ms (relógio e sincronia labial); o app atende NACK
///    (reenvia pacotes) e PLI (manda keyframe).
///
/// Referência do formato: media/cast (Chromium) e Open Screen (cast/streaming).
final class CastStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let receiverApp = "0F5096E8"
    static let namespace = "urn:x-cast:com.google.cast.webrtc"

    let width: Int
    let height: Int
    let fps = 30
    let targetDelayMs = 200
    let bitrate = 4_000_000
    let withAudio: Bool

    var onError: ((String) -> Void)?
    private(set) var sentFrames = 0
    private(set) var sentAudioFrames = 0
    private(set) var rtcpPackets = 0
    private(set) var retransmits = 0
    private(set) var keyframeRequests = 0
    private(set) var lastAckVideo: Int = -1
    private(set) var lastAckAudio: Int = -1

    private let video = RtpStream(payloadType: 96, clockRate: 90_000)
    private let audio = RtpStream(payloadType: 127, clockRate: 48_000)

    private let queue = DispatchQueue(label: "cast.streamer")
    private var udp: NWConnection?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var opus: OpusEncoder?
    private var srTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var patternTimer: DispatchSourceTimer?

    private var forceKeyFrame = true
    private let clockStart = CMClockGetTime(CMClockGetHostTimeClock())
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast

    // áudio: amostras intercaladas (L, R) esperando completar 20 ms
    private var pcm: [Float] = []
    private var pcmStart = 0.0                 // segundos desde clockStart da 1ª amostra em `pcm`
    private var rmsWindow: [Float] = []
    private var lastLevelLog = Date()

    init(maxWidth: Int = 1280, withAudio: Bool = true) {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let w = min(maxWidth, Int(screen.width))
        width = w / 2 * 2
        height = min(Int(Double(w) * screen.height / screen.width), 800) / 2 * 2
        self.withAudio = withAudio
    }

    // MARK: - Oferta

    /// Mensagem OFFER (o canal Cast é do CastStore, que manda e devolve o ANSWER).
    func offer(seqNum: Int) -> [String: Any] {
        var streams: [[String: Any]] = [[
            "index": 0, "type": "video_source", "codecName": "h264", "rtpProfile": "cast",
            "rtpPayloadType": Int(video.payloadType), "ssrc": Int(video.ssrc), "targetDelay": targetDelayMs,
            "aesKey": video.key.hex, "aesIvMask": video.ivMask.hex,
            "timeBase": "1/90000", "maxFrameRate": "\(fps * 1000)/1000", "maxBitRate": bitrate,
            "resolutions": [["width": width, "height": height]], "receiverRtcpEventLog": false,
        ]]
        if withAudio {
            streams.append([
                "index": 1, "type": "audio_source", "codecName": "opus", "rtpProfile": "cast",
                "rtpPayloadType": Int(audio.payloadType), "ssrc": Int(audio.ssrc), "targetDelay": targetDelayMs,
                "aesKey": audio.key.hex, "aesIvMask": audio.ivMask.hex,
                "timeBase": "1/48000", "bitRate": 128_000, "sampleRate": 48_000, "channels": 2,
                "receiverRtcpEventLog": false,
            ])
        }
        return ["type": "OFFER", "seqNum": seqNum,
                "offer": ["castMode": "mirroring", "receiverGetStatus": true, "supportedStreams": streams]]
    }

    /// Recebeu o ANSWER: abre o UDP e começa a capturar. `audioAccepted` vem do sendIndexes da resposta.
    func start(host: String, port: UInt16, audioAccepted: Bool = true, testPattern: Bool = false) async throws {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        c.start(queue: queue)
        udp = c
        receiveRTCP()
        try setupEncoder()
        if withAudio, audioAccepted { opus = OpusEncoder() }
        startSenderReports()
        if testPattern { startTestPattern() } else { try await startCapture() }
        startIdleRefresh()
    }

    func stop() {
        srTimer?.cancel(); srTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        patternTimer?.cancel(); patternTimer = nil
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async {
            if let e = self.encoder { VTCompressionSessionInvalidate(e) }
            self.encoder = nil
            self.opus = nil
            self.udp?.cancel(); self.udp = nil
            self.video.history.removeAll(); self.audio.history.removeAll()
        }
    }

    // MARK: - Captura (tela + som do sistema)

    private func startCapture() async throws {
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
        cfg.queueDepth = 4
        cfg.capturesAudio = opus != nil
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if opus != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pb = sb.imageBuffer else { return }
            lastPixelBuffer = pb
            encode(pb, at: sb.presentationTimeStamp)
        case .audio:
            handleAudio(sb)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    /// Tela parada não gera quadros: reenvia o último a cada 0,5 s pra TV não achar que caiu.
    private func startIdleRefresh() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, let pb = self.lastPixelBuffer, Date().timeIntervalSince(self.lastFrameAt) > 0.45 else { return }
            self.encode(pb, at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        t.resume()
        idleTimer = t
    }

    /// Padrão de teste animado (valida o caminho todo sem permissão de gravação de tela).
    private func startTestPattern() {
        var n = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, self.width, self.height, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
            let stride = CVPixelBufferGetBytesPerRow(pb) / 4
            let bar = (n * 16) % self.width
            for y in 0..<self.height {
                let row = base + y * stride
                let color = UInt32(0xFF00_0000) | UInt32((y * 255 / self.height) << 8) | UInt32((n * 3) % 255)
                for x in 0..<self.width { row[x] = abs(x - bar) < 30 ? 0xFFFF_FFFF : color | UInt32(x * 255 / self.width) << 16 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            self.lastPixelBuffer = pb
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.encode(pb, at: now)
            // tom de 440 Hz junto, pra testar o áudio
            if self.opus != nil {
                let frames = 48_000 / self.fps
                let t0 = Double(n * frames)
                var tone = [Float](repeating: 0, count: frames * 2)
                for i in 0..<frames {
                    let v = Float(sin(2 * Double.pi * 440 * (t0 + Double(i)) / 48_000) * 0.05)
                    tone[i * 2] = v; tone[i * 2 + 1] = v
                }
                self.appendPCM(tone, at: (now - self.clockStart).seconds)
            }
            n += 1
        }
        t.resume()
        patternTimer = t
    }

    // MARK: - Vídeo: H.264 (VideoToolbox, tempo real)

    private func setupEncoder() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw NSError(domain: "VT", code: Int(status)) }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,          // sem quadros B: menos atraso
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,        // keyframe de segurança a cada 2 s
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        for (k, v) in props { VTSessionSetProperty(session, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
    }

    private func encode(_ pb: CVPixelBuffer, at pts: CMTime) {
        guard let encoder else { return }
        lastFrameAt = Date()
        var frameProps: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: frameProps, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.queue.async { self.sendVideo(sb) }
        }
    }

    private func sendVideo(_ sb: CMSampleBuffer) {
        guard let block = sb.dataBuffer, let format = sb.formatDescription else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var annexB = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey {   // SPS/PPS na frente de cada keyframe
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { annexB.append(contentsOf: startCode); annexB.append(ptr, count: size) }
            }
        }
        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &dataPtr) == noErr, let dataPtr else { return }
        let avcc = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {   // AVCC (tamanho de 4 bytes) → start codes
            let nalLen = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16 | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            offset += 4
            guard offset + nalLen <= length else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(avcc + offset, count: nalLen)
            offset += nalLen
        }
        send(annexB, on: video, isKey: isKey, rtpTime: video.rtpTime((sb.presentationTimeStamp - clockStart).seconds))
        sentFrames += 1
    }

    // MARK: - Áudio: PCM → Opus (20 ms) → RTP

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard opus != nil, let fd = sb.formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr,
              let ch = buffer.floatChannelData else { return }
        let n = Int(frames)
        var interleaved = [Float](repeating: 0, count: n * 2)
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            let src = ch[0]
            for i in 0..<n {
                interleaved[i * 2] = src[i * channels]
                interleaved[i * 2 + 1] = src[i * channels + min(1, channels - 1)]
            }
        } else {
            let l = ch[0], r = ch[min(1, channels - 1)]
            for i in 0..<n { interleaved[i * 2] = l[i]; interleaved[i * 2 + 1] = r[i] }
        }
        appendPCM(interleaved, at: (sb.presentationTimeStamp - clockStart).seconds)
    }

    private func appendPCM(_ samples: [Float], at time: Double) {
        if pcm.isEmpty { pcmStart = time }
        pcm.append(contentsOf: samples)
        rmsWindow.append(contentsOf: samples.prefix(2048))
        let chunk = OpusEncoder.frameSamples * 2
        while pcm.count >= chunk {
            let frame = Array(pcm.prefix(chunk))
            pcm.removeFirst(chunk)
            if let packet = opus?.encode(frame) {
                send(packet, on: audio, isKey: true, rtpTime: audio.rtpTime(pcmStart))
                sentAudioFrames += 1
            }
            pcmStart += Double(OpusEncoder.frameSamples) / 48_000
        }
        logLevelIfNeeded()
    }

    /// Nível do som capturado no log (diagnóstico: 0 = nada chegando da captura).
    private func logLevelIfNeeded() {
        guard Date().timeIntervalSince(lastLevelLog) > 3, !rmsWindow.isEmpty else { return }
        let rms = sqrt(rmsWindow.reduce(0) { $0 + $1 * $1 } / Float(rmsWindow.count))
        log.notice("mirror: áudio rms=\(rms, format: .fixed(precision: 4)) quadros=\(self.sentAudioFrames)")
        rmsWindow.removeAll(keepingCapacity: true)
        lastLevelLog = Date()
    }

    // MARK: - Quadro → AES-CTR → RTP

    private func send(_ frame: Data, on s: RtpStream, isKey: Bool, rtpTime: UInt32) {
        let id = s.frameId
        s.frameId &+= 1
        let packets = s.packetize(s.crypt(frame, frameId: id), frameId: id, isKey: isKey, rtpTime: rtpTime)
        s.history[UInt8(truncatingIfNeeded: id)] = packets
        s.history.removeValue(forKey: UInt8(truncatingIfNeeded: id &- 100))
        for p in packets { udp?.send(content: p, completion: .idempotent) }
    }

    // MARK: - RTCP

    private func startSenderReports() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = (CMClockGetTime(CMClockGetHostTimeClock()) - self.clockStart).seconds
            self.udp?.send(content: self.video.senderReport(mediaTime: now), completion: .idempotent)
            if self.opus != nil { self.udp?.send(content: self.audio.senderReport(mediaTime: now), completion: .idempotent) }
        }
        t.resume()
        srTimer = t
    }

    private func receiveRTCP() {
        udp?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.rtcpPackets += 1; self.handleRTCP(data) }
            self.receiveRTCP()
        }
    }

    /// Pacote RTCP composto: PLI (pede keyframe) e feedback "CAST" (ACK + NACK), roteados pelo SSRC de mídia.
    private func handleRTCP(_ d: Data) {
        let b = [UInt8](d)
        var i = 0
        while i + 4 <= b.count {
            let fmt = b[i] & 0x1F, pt = b[i + 1]
            let len = (Int(b[i + 2]) << 8 | Int(b[i + 3]) + 1) * 4
            guard len > 0, i + len <= b.count else { return }
            if pt == 206, len >= 12 {
                let media = UInt32(b[i + 8]) << 24 | UInt32(b[i + 9]) << 16 | UInt32(b[i + 10]) << 8 | UInt32(b[i + 11])
                let s = media == audio.ssrc ? audio : video
                if fmt == 1, s === video { forceKeyFrame = true; keyframeRequests += 1 }       // PLI
                if fmt == 15, len >= 20, b[i + 12] == 0x43, b[i + 13] == 0x41, b[i + 14] == 0x53, b[i + 15] == 0x54 {
                    if s === audio { lastAckAudio = Int(b[i + 16]) } else { lastAckVideo = Int(b[i + 16]) }
                    let losses = Int(b[i + 17])
                    var j = i + 20
                    for _ in 0..<losses where j + 4 <= i + len {
                        retransmit(s, frame: b[j], packet: Int(b[j + 1]) << 8 | Int(b[j + 2]), mask: b[j + 3])
                        j += 4
                    }
                }
            }
            i += len
        }
    }

    private func retransmit(_ s: RtpStream, frame: UInt8, packet: Int, mask: UInt8) {
        guard let packets = s.history[frame] else {
            if s === video { forceKeyFrame = true }       // velho demais: recomeça do keyframe
            return
        }
        if packet == 0xFFFF { packets.forEach { udp?.send(content: $0, completion: .idempotent) }; retransmits += packets.count; return }
        var ids = [packet]
        for bit in 0..<8 where mask & (1 << bit) != 0 { ids.append(packet + bit + 1) }
        for id in ids where id < packets.count { udp?.send(content: packets[id], completion: .idempotent); retransmits += 1 }
    }
}

/// Um fluxo RTP do Cast Streaming (vídeo ou áudio): SSRC, chave AES, numeração e histórico.
private final class RtpStream {
    let ssrc = UInt32.random(in: 1...0x00FF_FFFF)
    let key: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    let ivMask: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    let payloadType: UInt8
    let clockRate: Double
    var frameId: UInt32 = 0
    var sequence: UInt16 = 0
    var packetCount: UInt32 = 0
    var octetCount: UInt32 = 0
    /// Pacotes dos últimos quadros, pra atender NACK.
    var history: [UInt8: [Data]] = [:]

    init(payloadType: UInt8, clockRate: Double) {
        self.payloadType = payloadType
        self.clockRate = clockRate
    }

    func rtpTime(_ seconds: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64(seconds * clockRate)) }

    /// AES-128-CTR; nonce = ivMask XOR frame_id (big-endian nos bytes 8…11).
    func crypt(_ data: Data, frameId: UInt32) -> Data {
        var nonce = ivMask
        nonce[8] ^= UInt8(frameId >> 24 & 0xFF); nonce[9] ^= UInt8(frameId >> 16 & 0xFF)
        nonce[10] ^= UInt8(frameId >> 8 & 0xFF); nonce[11] ^= UInt8(frameId & 0xFF)
        var cryptor: CCCryptorRef?
        CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                nonce, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count)
        var moved = 0
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in _ = CCCryptorUpdate(cryptor, i.baseAddress, data.count, o.baseAddress, data.count, &moved) }
        }
        return out
    }

    /// RTP (12 bytes) + cabeçalho Cast: [K|R|ext] [frame id] [packet id 16] [max packet id 16] [ref frame id].
    func packetize(_ payload: Data, frameId: UInt32, isKey: Bool, rtpTime: UInt32) -> [Data] {
        let maxPayload = 1300
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        let refId = isKey ? frameId : frameId &- 1
        var packets: [Data] = []
        for i in 0..<count {
            var p = Data(capacity: 1400)
            p.append(0x80)
            p.append((i == count - 1 ? 0x80 : 0) | payloadType)
            p.append(bigEndian: sequence)
            sequence &+= 1
            p.append(bigEndian: rtpTime)
            p.append(bigEndian: ssrc)
            p.append((isKey ? 0x80 : 0) | 0x40)                         // K, R, 0 extensões
            p.append(UInt8(truncatingIfNeeded: frameId))
            p.append(bigEndian: UInt16(i))
            p.append(bigEndian: UInt16(count - 1))
            p.append(UInt8(truncatingIfNeeded: refId))
            let start = i * maxPayload
            p.append(payload[payload.startIndex + start ..< payload.startIndex + min(start + maxPayload, payload.count)])
            packetCount &+= 1
            octetCount &+= UInt32(min(maxPayload, payload.count - start))
            packets.append(p)
        }
        return packets
    }

    /// Sender Report: liga o relógio RTP deste fluxo ao relógio de parede (a TV sincroniza vídeo e áudio por ele).
    func senderReport(mediaTime: Double) -> Data {
        let now = Date().timeIntervalSince1970 + 2_208_988_800          // época NTP (1900)
        var sr = Data([0x80, 200, 0, 6])
        sr.append(bigEndian: ssrc)
        sr.append(bigEndian: UInt32(truncatingIfNeeded: Int64(now)))
        sr.append(bigEndian: UInt32(truncatingIfNeeded: Int64((now - floor(now)) * 4_294_967_296)))
        sr.append(bigEndian: rtpTime(mediaTime))
        sr.append(bigEndian: packetCount)
        sr.append(bigEndian: octetCount)
        return sr
    }
}

/// PCM float 48 kHz estéreo → pacotes Opus de 20 ms (codificador nativo do macOS).
private final class OpusEncoder {
    static let frameSamples = 960
    private var converter: AudioConverterRef?

    init?() {
        var input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 2,
            mBitsPerChannel: 0, mReserved: 0)
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        var rate: UInt32 = 128_000
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    private struct Input {
        var data: UnsafeMutableRawPointer
        var bytes: UInt32
        var used: Bool
    }

    /// `samples` = 960 quadros intercalados (L, R).
    func encode(_ samples: [Float]) -> Data? {
        guard let converter else { return nil }
        var copy = samples
        return copy.withUnsafeMutableBytes { raw -> Data? in
            var input = Input(data: raw.baseAddress!, bytes: UInt32(raw.count), used: false)
            var out = [UInt8](repeating: 0, count: 4000)
            var desc = AudioStreamPacketDescription()
            var packets: UInt32 = 1
            let status: OSStatus = out.withUnsafeMutableBytes { outRaw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(outRaw.count), mData: outRaw.baseAddress))
                return withUnsafeMutablePointer(to: &input) { inputPtr in
                    AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, user in
                        let ctx = user!.assumingMemoryBound(to: Input.self)
                        if ctx.pointee.used { ioPackets.pointee = 0; return 1 }   // 1 = "acabou por agora"
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mData = ctx.pointee.data
                        ioData.pointee.mBuffers.mDataByteSize = ctx.pointee.bytes
                        ioData.pointee.mBuffers.mNumberChannels = 2
                        ioPackets.pointee = ctx.pointee.bytes / 8
                        ctx.pointee.used = true
                        return noErr
                    }, inputPtr, &packets, &list, &desc)
                }
            }
            guard packets > 0, status == noErr || status == 1, desc.mDataByteSize > 0 else { return nil }
            let start = Int(desc.mStartOffset)
            return Data(out[start ..< start + Int(desc.mDataByteSize)])
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
