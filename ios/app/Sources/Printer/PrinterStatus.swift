import SwiftUI

/// State of a Bambu Lab printer, built from the "print" object of the MQTT reports
/// (topic device/<serial>/report). P1 series printers send only the fields that
/// changed, so reports are merged into one dictionary; X1 series send everything.
struct PrinterStatus {
    private(set) var raw: [String: Any] = [:]
    private(set) var firmware = ""

    var isEmpty: Bool { raw.isEmpty }

    mutating func merge(report: [String: Any]) {
        if let print = report["print"] as? [String: Any] {
            raw = Self.merged(raw, print)
        }
        // Answer to "get_version": list of modules, "ota" is the main firmware.
        if let info = report["info"] as? [String: Any], let modules = info["module"] as? [[String: Any]],
           let ota = modules.first(where: { $0["name"] as? String == "ota" }),
           let version = ota["sw_ver"] as? String {
            firmware = version
        }
    }

    private static func merged(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
        var out = old
        for (key, value) in new {
            if let dict = value as? [String: Any], let previous = out[key] as? [String: Any] {
                out[key] = merged(previous, dict)
            } else {
                out[key] = value
            }
        }
        return out
    }

    // MARK: - Fields

    var gcodeState: String { raw["gcode_state"] as? String ?? "" }

    var stateLabel: String {
        switch gcodeState {
        case "IDLE": return "Inattiva"
        case "PREPARE": return "In preparazione"
        case "SLICING": return "Elaborazione"
        case "RUNNING": return "In stampa"
        case "PAUSE": return "In pausa"
        case "FINISH": return "Stampa completata"
        case "FAILED": return "Stampa fallita"
        case "": return "Sconosciuto"
        default: return gcodeState.capitalized
        }
    }

    var stateColor: Color {
        switch gcodeState {
        case "RUNNING", "PREPARE": return .green
        case "PAUSE": return .orange
        case "FAILED": return .red
        case "FINISH": return .blue
        default: return .secondary
        }
    }

    var isPrinting: Bool { ["RUNNING", "PREPARE", "PAUSE"].contains(gcodeState) }

    var jobName: String { raw["subtask_name"] as? String ?? raw["gcode_file"] as? String ?? "" }
    var percent: Int? { Self.int(raw["mc_percent"]) }
    var remainingMinutes: Int? { Self.int(raw["mc_remaining_time"]) }
    var layer: Int? { Self.int(raw["layer_num"]) }
    var totalLayers: Int? { Self.int(raw["total_layer_num"]) }

    var nozzle: Double? { Self.double(raw["nozzle_temper"]) }
    var nozzleTarget: Double? { Self.double(raw["nozzle_target_temper"]) }
    var bed: Double? { Self.double(raw["bed_temper"]) }
    var bedTarget: Double? { Self.double(raw["bed_target_temper"]) }
    var chamber: Double? { Self.double(raw["chamber_temper"]) }

    /// Fan speeds come as "0"..."15": converted to percent.
    var partFan: Int? { Self.fan(raw["cooling_fan_speed"]) }
    var auxFan: Int? { Self.fan(raw["big_fan1_speed"]) }
    var chamberFan: Int? { Self.fan(raw["big_fan2_speed"]) }

    var speedLabel: String? {
        switch Self.int(raw["spd_lvl"]) {
        case 1: return "Silenziosa"
        case 2: return "Standard"
        case 3: return "Sport"
        case 4: return "Ludicrous"
        default: return nil
        }
    }

    var wifiSignal: String? { raw["wifi_signal"] as? String }
    var printError: Int { Self.int(raw["print_error"]) ?? 0 }
    var hmsCount: Int { (raw["hms"] as? [Any])?.count ?? 0 }

    var chamberLightOn: Bool? {
        guard let lights = raw["lights_report"] as? [[String: Any]],
              let chamber = lights.first(where: { $0["node"] as? String == "chamber_light" }) else { return nil }
        return chamber["mode"] as? String == "on"
    }

    struct Tray: Identifiable {
        let id: String          // "A1".."D4", or "Esterna"
        let type: String
        let color: Color?
        let remain: Int?        // percent, -1/nil when unknown
        let active: Bool
        let humidity: String?
    }

    /// AMS slots plus the external spool holder.
    var trays: [Tray] {
        var out: [Tray] = []
        let ams = raw["ams"] as? [String: Any]
        let trayNow = Self.int(ams?["tray_now"])
        for unit in ams?["ams"] as? [[String: Any]] ?? [] {
            let unitIndex = Self.int(unit["id"]) ?? 0
            let letter = String(UnicodeScalar(UInt8(65 + min(max(unitIndex, 0), 25))))
            for tray in unit["tray"] as? [[String: Any]] ?? [] {
                let slot = Self.int(tray["id"]) ?? 0
                out.append(Tray(id: "\(letter)\(slot + 1)",
                                type: tray["tray_type"] as? String ?? "",
                                color: Self.color(tray["tray_color"] as? String),
                                remain: Self.int(tray["remain"]),
                                active: trayNow == unitIndex * 4 + slot,
                                humidity: unit["humidity"] as? String))
            }
        }
        if let ext = raw["vt_tray"] as? [String: Any], let type = ext["tray_type"] as? String, !type.isEmpty {
            out.append(Tray(id: "Esterna", type: type, color: Self.color(ext["tray_color"] as? String),
                            remain: nil, active: trayNow == 254, humidity: nil))
        }
        return out
    }

    // MARK: - Value helpers (fields arrive as numbers or strings)

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    private static func fan(_ v: Any?) -> Int? {
        int(v).map { Int((Double($0) / 15 * 100).rounded()) }
    }

    /// "RRGGBBAA" hex.
    private static func color(_ hex: String?) -> Color? {
        guard let hex, hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
