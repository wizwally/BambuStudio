import CryptoKit
import Foundation
import Network
import Security

/// Minimal MQTT 3.1.1 client over TLS, enough for a Bambu Lab printer in the LAN:
/// CONNECT with username/password, SUBSCRIBE and PUBLISH at QoS 0, keep-alive pings.
///
/// Bambu printers present a certificate signed by Bambu's own CA, so the usual
/// system validation cannot succeed. Instead the client pins the printer's
/// certificate (SHA-256 of the leaf, "trust on first use"): the first connection
/// records it, later connections must present the same one.
final class MQTTClient {
    enum Event {
        case connected(certificateSHA256: String)
        case message(topic: String, payload: Data)
        case disconnected(Error?)
    }

    enum Failure: LocalizedError {
        case refused(UInt8)
        case certificateChanged
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .refused(4): return "Codice di accesso o utente non validi"
            case .refused(5): return "Connessione non autorizzata dalla stampante"
            case .refused(let code): return "Connessione rifiutata (codice MQTT \(code))"
            case .certificateChanged:
                return "Il certificato della stampante è cambiato. Se hai sostituito la stampante o il firmware lo ha rigenerato, usa \"Dimentica certificato\"."
            case .protocolError(let s): return "Errore di protocollo MQTT: \(s)"
            }
        }
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private let host: String
    private let port: UInt16
    private let clientID: String
    private let username: String
    private let password: String
    private let pinnedSHA256: String?
    private let keepAlive: UInt16 = 60

    private let queue = DispatchQueue(label: "SlicerPoC.mqtt")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var pingTimer: DispatchSourceTimer?
    private var nextPacketID: UInt16 = 1
    private var seenSHA256 = ""
    private var certificateRejected = false
    private var finished = false
    private var subscriptions: [String] = []

    init(host: String, port: UInt16 = 8883, clientID: String, username: String, password: String,
         pinnedSHA256: String?) {
        self.host = host
        self.port = port
        self.clientID = clientID
        self.username = username
        self.password = password
        self.pinnedSHA256 = pinnedSHA256
    }

    // MARK: - Public API (any thread)

    func connect(subscribeTo topics: [String]) {
        queue.async { [self] in
            subscriptions = topics
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                complete(self?.verify(trust) ?? false)
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                    using: NWParameters(tls: tls, tcp: tcp))
            conn.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            connection = conn
            conn.start(queue: queue)
        }
    }

    func publish(topic: String, payload: Data) {
        queue.async { [self] in
            var body = Self.string(topic)
            body.append(contentsOf: payload)
            send(Self.packet(0x30, body))
        }
    }

    func disconnect() {
        queue.async { [self] in
            guard !finished else { return }
            send([0xE0, 0x00])
            finish(nil)
        }
    }

    // MARK: - TLS certificate pinning (mqtt queue)

    private func verify(_ trust: sec_trust_t) -> Bool {
        let ref = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(ref) as? [SecCertificate], let leaf = chain.first else {
            return false
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        seenSHA256 = digest
        if let pinned = pinnedSHA256, !pinned.isEmpty, pinned != digest {
            certificateRejected = true
            return false
        }
        return true
    }

    // MARK: - Connection (mqtt queue)

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendConnect()
            receive()
        case .waiting(let error), .failed(let error):
            finish(certificateRejected ? Failure.certificateChanged : error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        emit(.disconnected(error))
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.queue.async { self?.finish(error) } }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
                parse()
            }
            if let error { finish(error); return }
            if isComplete { finish(nil); return }
            if !finished { receive() }
        }
    }

    // MARK: - MQTT packets

    private func sendConnect() {
        var body = Self.string("MQTT")
        body.append(4)                       // protocol level 3.1.1
        body.append(0xC2)                    // username + password + clean session
        body.append(contentsOf: [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])
        body += Self.string(clientID) + Self.string(username) + Self.string(password)
        send(Self.packet(0x10, body))
    }

    private func subscribe(_ topic: String) {
        let id = nextPacketID
        nextPacketID &+= 1
        var body: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF)]
        body += Self.string(topic)
        body.append(0)                       // QoS 0
        send(Self.packet(0x82, body))
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(keepAlive) / 2
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.send([0xC0, 0x00]) }
        timer.resume()
        pingTimer = timer
    }

    private func parse() {
        while buffer.count >= 2 {
            // Remaining length: 1-4 bytes, 7 bits each.
            var length = 0, multiplier = 1, index = 1
            while true {
                guard index < buffer.count else { return }       // incomplete header
                let byte = buffer[index]
                length += Int(byte & 0x7F) * multiplier
                index += 1
                if byte & 0x80 == 0 { break }
                multiplier *= 128
                if index > 4 { finish(Failure.protocolError("lunghezza non valida")); return }
            }
            let total = index + length
            guard buffer.count >= total else { return }          // wait for the rest
            let header = buffer[0]
            let body = Array(buffer[index..<total])
            buffer.removeFirst(total)
            dispatch(header: header, body: body)
        }
    }

    private func dispatch(header: UInt8, body: [UInt8]) {
        switch header >> 4 {
        case 2: // CONNACK
            guard body.count >= 2 else { finish(Failure.protocolError("CONNACK corto")); return }
            if body[1] != 0 { finish(Failure.refused(body[1])); return }
            subscriptions.forEach(subscribe)
            startPing()
            emit(.connected(certificateSHA256: seenSHA256))
        case 3: // PUBLISH
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + topicLength else { return }
            let topic = String(decoding: body[2..<(2 + topicLength)], as: UTF8.self)
            var start = 2 + topicLength
            if (header >> 1) & 0x03 > 0 { start += 2 }            // packet id (QoS 1/2)
            guard start <= body.count else { return }
            emit(.message(topic: topic, payload: Data(body[start...])))
        default: // SUBACK, PINGRESP, ...
            break
        }
    }

    private static func packet(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [type]
        var n = body.count
        repeat {
            var byte = UInt8(n % 128)
            n /= 128
            if n > 0 { byte |= 0x80 }
            out.append(byte)
        } while n > 0
        return out + body
    }

    private static func string(_ s: String) -> [UInt8] {
        let utf8 = Array(s.utf8)
        return [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)] + utf8
    }
}
