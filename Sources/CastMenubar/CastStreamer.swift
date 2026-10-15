import CommonCrypto
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

/// Espelhamento instantâneo pelo Cast Streaming — o mesmo protocolo do "transmitir aba" do Chrome.
///
/// 1. Abre o receptor de espelhamento (0F5096E8) e manda um OFFER em `urn:x-cast:com.google.cast.webrtc`.
/// 2. O ANSWER traz a porta UDP do aparelho.
/// 3. Cada quadro H.264 (Annex B) é criptografado com AES-128-CTR e enviado em pacotes RTP com o cabeçalho Cast.
/// 4. RTCP: Sender Report a cada 500 ms (relógio), e o app atende NACK (reenvia pacotes) e PLI (manda keyframe).
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

    // sessão
    let ssrc = UInt32.random(in: 1...0x00FF_FFFF)
    private let aesKey: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    private let aesIvMask: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    private let payloadType: UInt8 = 96

    var onError: ((String) -> Void)?
    /// Quadros que a TV confirmou ter recebido (pra diagnóstico).
    private(set) var ackedFrames = 0
    private(set) var sentFrames = 0
    private(set) var rtcpPackets = 0
    private(set) var retransmits = 0
    private(set) var keyframeRequests = 0

    private let queue = DispatchQueue(label: "cast.streamer")
    private var udp: NWConnection?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var srTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var patternTimer: DispatchSourceTimer?

    private var frameId: UInt32 = 0
    private var sequence: UInt16 = 0
    private var packetCount: UInt32 = 0
    private var octetCount: UInt32 = 0
    private var forceKeyFrame = true
    private let clockStart = CMClockGetTime(CMClockGetHostTimeClock())
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast
    /// Pacotes dos últimos quadros, pra atender NACK.
    private var history: [UInt8: [Data]] = [:]

    init(maxWidth: Int = 1280) {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let w = min(maxWidth, Int(screen.width))
        width = w / 2 * 2
        height = min(Int(Double(w) * screen.height / screen.width), 800) / 2 * 2
    }

    // MARK: - Oferta

    /// Mensagem OFFER (o canal Cast é do CastStore, que manda e devolve o ANSWER).
    func offer(seqNum: Int) -> [String: Any] {
        let video: [String: Any] = [
            "index": 0, "type": "video_source", "codecName": "h264", "rtpProfile": "cast",
            "rtpPayloadType": Int(payloadType), "ssrc": Int(ssrc), "targetDelay": targetDelayMs,
            "aesKey": aesKey.hex, "aesIvMask": aesIvMask.hex,
            "timeBase": "1/90000", "maxFrameRate": "\(fps * 1000)/1000", "maxBitRate": bitrate,
            "resolutions": [["width": width, "height": height]], "receiverRtcpEventLog": false,
        ]
        return ["type": "OFFER", "seqNum": seqNum,
                "offer": ["castMode": "mirroring", "receiverGetStatus": true, "supportedStreams": [video]]]
    }

    /// Recebeu o ANSWER: abre o UDP e começa a capturar.
    func start(host: String, port: UInt16, testPattern: Bool = false) async throws {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        c.start(queue: queue)
        udp = c
        receiveRTCP()
        try setupEncoder()
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
            self.udp?.cancel(); self.udp = nil
            self.history.removeAll()
        }
    }

    // MARK: - Captura

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
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer else { return }
        lastPixelBuffer = pb
        encode(pb, at: sb.presentationTimeStamp)
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
            self.encode(pb, at: CMClockGetTime(CMClockGetHostTimeClock()))
            n += 1
        }
        t.resume()
        patternTimer = t
    }

    // MARK: - Codificador H.264 (VideoToolbox, tempo real)

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
            self.queue.async { self.send(encoded: sb) }
        }
    }

    // MARK: - Quadro → Annex B → AES-CTR → RTP

    private func send(encoded sb: CMSampleBuffer) {
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

        let id = frameId
        frameId &+= 1
        let rtpTime = rtpTimestamp(sb.presentationTimeStamp)
        let encrypted = crypt(annexB, frameId: id)
        let packets = packetize(encrypted, frameId: id, isKey: isKey, rtpTime: rtpTime)
        history[UInt8(truncatingIfNeeded: id)] = packets
        history.removeValue(forKey: UInt8(truncatingIfNeeded: id &- 60))
        for p in packets { udp?.send(content: p, completion: .idempotent) }
        sentFrames += 1
    }

    private func rtpTimestamp(_ t: CMTime) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(((t - clockStart).seconds) * 90_000))
    }

    /// AES-128-CTR; nonce = aesIvMask XOR frame_id (big-endian nos bytes 8…11).
    private func crypt(_ data: Data, frameId: UInt32) -> Data {
        var nonce = aesIvMask
        nonce[8] ^= UInt8(frameId >> 24 & 0xFF); nonce[9] ^= UInt8(frameId >> 16 & 0xFF)
        nonce[10] ^= UInt8(frameId >> 8 & 0xFF); nonce[11] ^= UInt8(frameId & 0xFF)
        var cryptor: CCCryptorRef?
        CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                nonce, aesKey, aesKey.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard let cryptor else { return data }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: data.count)
        var moved = 0
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                _ = CCCryptorUpdate(cryptor, i.baseAddress, data.count, o.baseAddress, data.count, &moved)
            }
        }
        return out
    }

    /// RTP (12 bytes) + cabeçalho Cast: [K|R|ext] [frame id] [packet id 16] [max packet id 16] [ref frame id].
    private func packetize(_ payload: Data, frameId: UInt32, isKey: Bool, rtpTime: UInt32) -> [Data] {
        let maxPayload = 1300
        let count = max(1, (payload.count + maxPayload - 1) / maxPayload)
        let refId = isKey ? frameId : frameId &- 1
        var packets: [Data] = []
        for i in 0..<count {
            var p = Data(capacity: 1400)
            p.append(0x80)
            p.append((i == count - 1 ? 0x80 : 0) | payloadType)
            p.append(UInt8(sequence >> 8)); p.append(UInt8(sequence & 0xFF))
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

    // MARK: - RTCP

    /// Sender Report: liga o relógio RTP ao relógio de parede pra TV calcular quando exibir cada quadro.
    private func startSenderReports() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.sendSenderReport() }
        t.resume()
        srTimer = t
    }

    private func sendSenderReport() {
        let now = Date().timeIntervalSince1970 + 2_208_988_800          // época NTP (1900)
        let seconds = UInt32(truncatingIfNeeded: Int64(now))
        let fraction = UInt32(truncatingIfNeeded: Int64((now - floor(now)) * 4_294_967_296))
        var sr = Data([0x80, 200, 0, 6])
        sr.append(bigEndian: ssrc)
        sr.append(bigEndian: seconds)
        sr.append(bigEndian: fraction)
        sr.append(bigEndian: rtpTimestamp(CMClockGetTime(CMClockGetHostTimeClock())))
        sr.append(bigEndian: packetCount)
        sr.append(bigEndian: octetCount)
        udp?.send(content: sr, completion: .idempotent)
    }

    private func receiveRTCP() {
        udp?.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.rtcpPackets += 1; self.handleRTCP(data) }
            self.receiveRTCP()
        }
    }

    /// Pacote RTCP composto: procura PLI (pede keyframe) e o feedback "CAST" (ACK + NACK).
    private func handleRTCP(_ d: Data) {
        let b = [UInt8](d)
        var i = 0
        while i + 4 <= b.count {
            let fmt = b[i] & 0x1F, pt = b[i + 1]
            let len = (Int(b[i + 2]) << 8 | Int(b[i + 3]) + 1) * 4
            guard len > 0, i + len <= b.count else { return }
            if pt == 206, fmt == 1 { forceKeyFrame = true; keyframeRequests += 1 }   // PLI
            if pt == 206, fmt == 15, len >= 20, b[i + 12] == 0x43, b[i + 13] == 0x41, b[i + 14] == 0x53, b[i + 15] == 0x54 {
                ackedFrames = Int(b[i + 16])
                let losses = Int(b[i + 17])
                var j = i + 20
                for _ in 0..<losses where j + 4 <= i + len {
                    let frame = b[j]
                    let packet = Int(b[j + 1]) << 8 | Int(b[j + 2])
                    let mask = b[j + 3]
                    retransmit(frame: frame, packet: packet, mask: mask)
                    j += 4
                }
            }
            i += len
        }
    }

    private func retransmit(frame: UInt8, packet: Int, mask: UInt8) {
        guard let packets = history[frame] else { forceKeyFrame = true; return }   // velho demais: recomeça do keyframe
        if packet == 0xFFFF { packets.forEach { udp?.send(content: $0, completion: .idempotent) }; return }
        var ids = [packet]
        for bit in 0..<8 where mask & (1 << bit) != 0 { ids.append(packet + bit + 1) }
        for id in ids where id < packets.count { udp?.send(content: packets[id], completion: .idempotent); retransmits += 1 }
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
