import Foundation
import Security
import SwiftUI

/// LAN connection to one Bambu Lab printer, read-only for now: status reports over
/// MQTT (TLS, port 8883, user "bblp", password = the access code on the printer screen).
/// IP and serial are kept in UserDefaults, the access code in the Keychain.
@MainActor
final class PrinterConnection: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Non collegata"
            case .connecting: return "Connessione…"
            case .connected: return "Collegata"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state = State.disconnected
    @Published private(set) var status = PrinterStatus()
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var messageCount = 0
    @Published var host: String { didSet { defaults.set(host, forKey: "PrinterHost") } }
    @Published var serial: String { didSet { defaults.set(serial, forKey: "PrinterSerial") } }

    var hasConfiguration: Bool { !host.isEmpty && !serial.isEmpty && !accessCode.isEmpty }

    var accessCode: String {
        get { Keychain.read(account: serial) ?? "" }
        set { Keychain.write(newValue, account: serial); objectWillChange.send() }
    }

    /// SHA-256 of the printer certificate seen on the first connection (pinning).
    var pinnedCertificate: String? {
        get { defaults.string(forKey: "PrinterCert.\(serial)") }
        set { defaults.set(newValue, forKey: "PrinterCert.\(serial)"); objectWillChange.send() }
    }

    private let defaults = UserDefaults.standard
    private var client: MQTTClient?
    private var wantConnected = false
    private var retryTask: Task<Void, Never>?
    /// For the autotest: credentials that are not saved.
    private var overrideAccessCode: String?

    init() {
        host = UserDefaults.standard.string(forKey: "PrinterHost") ?? ""
        serial = UserDefaults.standard.string(forKey: "PrinterSerial") ?? ""
    }

    func connect() {
        wantConnected = true
        open()
    }

    func disconnect() {
        wantConnected = false
        retryTask?.cancel()
        client?.disconnect()
        client = nil
        state = .disconnected
    }

    /// Autotest only: connects with explicit settings, nothing is stored.
    func connectForTest(host: String, serial: String, accessCode: String) {
        self.host = host
        self.serial = serial
        overrideAccessCode = accessCode
        pinnedCertificate = nil
        connect()
    }

    func forgetCertificate() {
        pinnedCertificate = nil
    }

    /// Reconnects when the app comes back to the foreground (iOS drops sockets in background).
    func resume() {
        if wantConnected, client == nil { open() }
    }

    private func open() {
        retryTask?.cancel()
        client?.onEvent = nil
        client?.disconnect()
        let code = overrideAccessCode ?? accessCode
        let host = host.trimmingCharacters(in: .whitespaces)
        let serial = serial.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !serial.isEmpty, !code.isEmpty else {
            state = .failed("Inserisci indirizzo IP, numero di serie e codice di accesso")
            return
        }
        state = .connecting
        let c = MQTTClient(host: host, clientID: "slicerpoc-\(UUID().uuidString.prefix(8))",
                           username: "bblp", password: code, pinnedSHA256: pinnedCertificate)
        c.onEvent = { [weak self] event in self?.handle(event, serial: serial) }
        client = c
        c.connect(subscribeTo: ["device/\(serial)/report"])
    }

    private func handle(_ event: MQTTClient.Event, serial: String) {
        switch event {
        case .connected(let sha):
            if pinnedCertificate == nil { pinnedCertificate = sha }
            state = .connected
            // Full status once (P1 printers then send only changes), and firmware version.
            request(serial: serial, ["pushing": ["sequence_id": "0", "command": "pushall"]])
            request(serial: serial, ["info": ["sequence_id": "1", "command": "get_version"]])
        case .message(_, let payload):
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
            status.merge(report: json)
            lastUpdate = Date()
            messageCount += 1
        case .disconnected(let error):
            client = nil
            if let error {
                state = .failed(Self.describe(error))
            } else {
                state = .disconnected
            }
            // Retry network drops, not wrong credentials or a changed certificate.
            let fatal = (error as? MQTTClient.Failure).map { f -> Bool in
                if case .protocolError = f { return false }
                return true
            } ?? false
            if wantConnected && !fatal {
                retryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.open()
                }
            } else if fatal {
                wantConnected = false
            }
        }
    }

    private func request(serial: String, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        client?.publish(topic: "device/\(serial)/request", payload: data)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? MQTTClient.Failure { return failure.localizedDescription }
        let text = error.localizedDescription
        return "Stampante non raggiungibile (\(text))"
    }
}

/// Generic-password Keychain items for the printer access code, one per serial.
enum Keychain {
    private static let service = "com.wizwally.slicerpoc.printer"

    static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
