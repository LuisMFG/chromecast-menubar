import Foundation
import Network

// Cast v2: TLS na porta 8009, mensagens protobuf `CastMessage` com prefixo de 4 bytes (big-endian).
//
// message CastMessage {
//   required ProtocolVersion protocol_version = 1;  // 0 = CASTV2_1_0
//   required string source_id = 2;
//   required string destination_id = 3;
//   required string namespace = 4;
//   required PayloadType payload_type = 5;           // 0 = STRING
//   optional string payload_utf8 = 6;
//   optional bytes payload_binary = 7;
// }

struct CastMessage {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    func encoded() -> Data {
        var d = Data()
        func varint(_ v: UInt64) { var v = v; repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0 }
        func string(_ field: UInt64, _ s: String) { varint(field << 3 | 2); let u = Data(s.utf8); varint(UInt64(u.count)); d.append(u) }
        varint(1 << 3); varint(0)
        string(2, source)
        string(3, destination)
        string(4, namespace)
        varint(5 << 3); varint(0)
        string(6, payload)
        return d
    }

    static func decode(_ data: Data) -> CastMessage? {
        var m = CastMessage(source: "", destination: "", namespace: "", payload: "")
        var i = data.startIndex
        func varint() -> UInt64? {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                r |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return r }
                shift += 7
            }
            return nil
        }
        while i < data.endIndex {
            guard let key = varint() else { return nil }
            let field = key >> 3, wire = key & 7
            switch wire {
            case 0: _ = varint()
            case 2:
                guard let len = varint(), i + Int(len) <= data.endIndex else { return nil }
                let bytes = data[i..<i + Int(len)]; i += Int(len)
                let s = String(decoding: bytes, as: UTF8.self)
                switch field {
                case 2: m.source = s
                case 3: m.destination = s
                case 4: m.namespace = s
                case 6: m.payload = s
                default: break
                }
            default: return nil
            }
        }
        return m
    }
}

enum CastNS {
    static let connection = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiver = "urn:x-cast:com.google.cast.receiver"
    static let media = "urn:x-cast:com.google.cast.media"
    /// API local de configuração tunelada no Cast (encontrada no app Google Home com REA).
    /// Formato: {"type": "<rota>", "request_id": n, "data": {...}} → {"response_code": 200, "data": ...}
    static let setup = "urn:x-cast:com.google.cast.setup"
    static let youtube = "urn:x-cast:com.google.youtube.mdx"
}

/// Conexão TLS com o Chromecast. O certificado do aparelho é autoassinado,
/// então a verificação é desligada (é um aparelho da rede local).
final class CastChannel: @unchecked Sendable {
    let endpoint: NWEndpoint
    let senderId = "sender-\(UUID().uuidString.prefix(8))"

    var onMessage: ((CastMessage) -> Void)?
    var onState: ((NWConnection.State) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cast.channel")
    private var buffer = Data()
    private var heartbeat: DispatchSourceTimer?
    /// Última vez que chegou qualquer coisa do aparelho (inclui PONG). Lido de outra thread: protegido pela fila.
    private var lastReceived = Date()

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    convenience init(host: String, port: UInt16 = 8009) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    func start() {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let params = NWParameters(tls: tls)
        // o Chromecast de 1ª geração só atende a porta 8009 em IPv4
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let c = NWConnection(to: endpoint, using: params)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.lastReceived = Date()
                self.send(to: "receiver-0", ns: CastNS.connection, ["type": "CONNECT"])
                self.startHeartbeat()
                self.receive()
            }
            self.onState?(state)
        }
        c.start(queue: queue)
    }

    /// IP local usado pra falar com o Chromecast (é o endereço que ele consegue alcançar de volta).
    var localAddress: String? {
        guard case let .hostPort(host, _)? = connection?.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return Self.plain(a)
        case .name(let n, _): return n
        default: return nil
        }
    }

    /// "192.168.1.10%en0" → "192.168.1.10". Pela conexão Bonjour o endereço vem com a interface,
    /// que não serve em URL nem pra abrir o UDP do espelhamento.
    static func plain(_ a: IPv4Address) -> String {
        String("\(a)".split(separator: "%").first ?? "")
    }

    /// IP do Chromecast nesta conexão (guardado pra reconectar mesmo se o Bonjour falhar).
    var remoteAddress: String? {
        guard case let .hostPort(host, _)? = connection?.currentPath?.remoteEndpoint, case .ipv4(let a) = host else { return nil }
        return Self.plain(a)
    }

    /// Há quantos segundos o aparelho não manda nada. O heartbeat garante resposta a cada 5 s numa conexão viva.
    var silence: TimeInterval { queue.sync { Date().timeIntervalSince(lastReceived) } }

    /// Encerra de vez: solta os callbacks ANTES de cancelar, pra que o "cancelado" desta conexão
    /// antiga nunca seja confundido com uma queda da conexão nova.
    func stop() {
        onState = nil
        onMessage = nil
        heartbeat?.cancel(); heartbeat = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        queue.async { self.buffer.removeAll() }
    }

    func send(to destination: String, ns: String, _ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let connection else { return }
        let body = CastMessage(source: senderId, destination: destination, namespace: ns,
                               payload: String(decoding: json, as: UTF8.self)).encoded()
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.send(to: "receiver-0", ns: CastNS.heartbeat, ["type": "PING"]) }
        t.resume()
        heartbeat = t
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.lastReceived = Date(); self.buffer.append(data); self.drain() }
            if done || error != nil { self.onState?(.cancelled); return }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard buffer.count >= 4 + len else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + len)
            guard let msg = CastMessage.decode(body) else { continue }
            if msg.namespace == CastNS.heartbeat, msg.payload.contains("\"PING\"") {
                send(to: msg.source, ns: CastNS.heartbeat, ["type": "PONG"])
                continue
            }
            onMessage?(msg)
        }
    }
}
