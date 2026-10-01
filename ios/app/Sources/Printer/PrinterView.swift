import SwiftUI

/// Sidebar row: printer state at a glance, opens the full panel.
struct PrinterSummaryRow: View {
    @EnvironmentObject var printer: PrinterConnection
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel = true
        } label: {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $showPanel) {
            PrinterPanel()
                .environmentObject(printer)
        }
    }

    private var dotColor: Color {
        switch printer.state {
        case .connected: return printer.status.isEmpty ? .yellow : printer.status.stateColor
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var title: String {
        guard printer.state == .connected else {
            return printer.hasConfiguration ? printer.state.label : "Configura la stampante"
        }
        return printer.status.isEmpty ? "In attesa di dati…" : printer.status.stateLabel
    }

    private var subtitle: String? {
        let s = printer.status
        guard printer.state == .connected, s.isPrinting else { return nil }
        var parts: [String] = []
        if let p = s.percent { parts.append("\(p)%") }
        if let l = s.layer, let t = s.totalLayers { parts.append("layer \(l)/\(t)") }
        if let m = s.remainingMinutes { parts.append(PrinterPanel.duration(m)) }
        return parts.joined(separator: " · ")
    }
}

/// Connection settings and live status of the printer.
struct PrinterPanel: View {
    @EnvironmentObject var printer: PrinterConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if printer.state == .connected && !printer.status.isEmpty {
                    jobSection
                    temperatureSection
                    if !printer.status.trays.isEmpty { amsSection }
                    deviceSection
                }
            }
            .navigationTitle("Stampante")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            TextField("Indirizzo IP (es. 192.168.1.50)", text: $printer.host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Numero di serie", text: $printer.serial)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            SecureField("Codice di accesso", text: Binding(get: { printer.accessCode },
                                                            set: { printer.accessCode = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text(printer.state.label)
                    .foregroundStyle(stateColor)
                    .font(.callout)
                Spacer()
                if printer.state == .connected || printer.state == .connecting {
                    Button("Disconnetti", role: .destructive) { printer.disconnect() }
                } else {
                    Button("Connetti") { printer.connect() }
                        .disabled(!printer.hasConfiguration)
                }
            }
            if printer.pinnedCertificate != nil {
                Button("Dimentica certificato della stampante") { printer.forgetCertificate() }
                    .font(.callout)
            }
        } header: {
            Text("Connessione in rete locale")
        } footer: {
            Text("Sullo schermo della P1S: Impostazioni → WLAN mostra indirizzo IP e codice di accesso. Il numero di serie è nelle informazioni del dispositivo (anche in Bambu Studio o Bambu Handy). Per ora l'app legge solo lo stato: non invia comandi di stampa.")
        }
    }

    private var jobSection: some View {
        let s = printer.status
        return Section("Stampa") {
            LabeledContent("Stato") {
                Text(s.stateLabel).foregroundStyle(s.stateColor)
            }
            if !s.jobName.isEmpty { LabeledContent("Lavoro", value: s.jobName) }
            if let p = s.percent {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(p), total: 100)
                    HStack {
                        Text("\(p)%")
                        Spacer()
                        if let l = s.layer, let t = s.totalLayers { Text("Layer \(l) / \(t)") }
                        Spacer()
                        if let m = s.remainingMinutes, s.isPrinting { Text("Mancano \(Self.duration(m))") }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            if let speed = s.speedLabel { LabeledContent("Velocità", value: speed) }
            if s.printError != 0 {
                LabeledContent("Errore") { Text(String(format: "0x%08X", s.printError)).foregroundStyle(.red) }
            }
            if s.hmsCount > 0 {
                LabeledContent("Avvisi HMS") { Text("\(s.hmsCount)").foregroundStyle(.orange) }
            }
        }
    }

    private var temperatureSection: some View {
        let s = printer.status
        return Section("Temperature e ventole") {
            temperature("Ugello", s.nozzle, s.nozzleTarget)
            temperature("Piatto", s.bed, s.bedTarget)
            if let c = s.chamber, c > 0 { temperature("Camera", c, nil) }
            if let f = s.partFan { LabeledContent("Ventola pezzo", value: "\(f)%") }
            if let f = s.auxFan { LabeledContent("Ventola ausiliaria", value: "\(f)%") }
            if let f = s.chamberFan { LabeledContent("Ventola camera", value: "\(f)%") }
        }
    }

    private var amsSection: some View {
        Section("Filamenti") {
            ForEach(printer.status.trays) { tray in
                HStack(spacing: 10) {
                    Circle()
                        .fill(tray.color ?? .clear)
                        .overlay(Circle().stroke(.secondary.opacity(0.5)))
                        .frame(width: 18, height: 18)
                    Text(tray.id).font(.callout.monospaced()).frame(width: 64, alignment: .leading)
                    Text(tray.type.isEmpty ? "Vuoto" : tray.type)
                        .foregroundStyle(tray.type.isEmpty ? .secondary : .primary)
                    Spacer()
                    if let r = tray.remain, r >= 0 { Text("\(r)%").foregroundStyle(.secondary) }
                    if tray.active { Image(systemName: "arrowtriangle.left.fill").foregroundStyle(.green) }
                }
            }
        }
    }

    private var deviceSection: some View {
        let s = printer.status
        return Section("Dispositivo") {
            if !s.firmware.isEmpty { LabeledContent("Firmware", value: s.firmware) }
            if let w = s.wifiSignal { LabeledContent("Segnale Wi-Fi", value: w) }
            if let light = s.chamberLightOn { LabeledContent("Luce camera", value: light ? "Accesa" : "Spenta") }
            if let t = printer.lastUpdate {
                LabeledContent("Ultimo aggiornamento") {
                    Text(t, style: .relative)
                }
            }
            LabeledContent("Messaggi ricevuti", value: "\(printer.messageCount)")
        }
    }

    // MARK: Helpers

    private func temperature(_ name: String, _ value: Double?, _ target: Double?) -> some View {
        LabeledContent(name) {
            if let value {
                if let target, target > 0 {
                    Text(String(format: "%.0f / %.0f °C", value, target))
                } else {
                    Text(String(format: "%.0f °C", value))
                }
            } else {
                Text("—")
            }
        }
    }

    private var stateColor: Color {
        switch printer.state {
        case .connected: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
