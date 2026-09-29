import Foundation

/// Printer / process / filament triple used for loading and slicing.
struct SliceProfile: Equatable {
    var printer: String
    var process: String
    var filament: String

    /// Gualti's Bambu Lab P1S, 0.4 nozzle, PLA Basic: first-launch default and autotest profile.
    static let p1sDefault = SliceProfile(printer: "Bambu Lab P1S 0.4 nozzle",
                                         process: "0.20mm Standard @BBL X1C",
                                         filament: "Bambu PLA Basic @BBL P1S 0.4 nozzle")
}

struct PresetGroup: Identifiable {
    let id: String          // group title
    let names: [String]
}

/// Bambu system presets for the pickers, filtered by the selected printer.
/// The selection is remembered across launches (UserDefaults).
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var profile: SliceProfile
    @Published private(set) var printerGroups: [PresetGroup] = []
    @Published private(set) var processes: [String] = []
    @Published private(set) var filamentGroups: [PresetGroup] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""

    private var cache: [String: SCPresetList] = [:]
    private let defaults = UserDefaults.standard
    private static let key = "SliceProfile"

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String],
           let printer = saved["printer"], let process = saved["process"], let filament = saved["filament"] {
            profile = SliceProfile(printer: printer, process: process, filament: filament)
        } else {
            profile = .p1sDefault
        }
    }

    /// Loads the lists for the current printer (once per printer, then cached).
    func load() async {
        await select(printer: profile.printer)
    }

    /// Changes printer; keeps process and filament if compatible, otherwise
    /// switches to the printer's defaults.
    func select(printer: String) async {
        loading = true
        defer { loading = false }
        guard let list = await presets(for: printer) else { return }
        guard !list.processes.isEmpty, !list.filaments.isEmpty else {
            error = "Nessun processo o filamento compatibile con \(printer)"
            return
        }
        error = ""
        if printerGroups.isEmpty {
            printerGroups = Self.groupPrinters(list.printers, models: list.printerModels)
        }
        processes = list.processes
        filamentGroups = Self.groupFilaments(list.filaments)

        var p = profile
        p.printer = printer
        if !list.processes.contains(p.process) {
            p.process = list.defaultProcess.isEmpty ? list.processes[0] : list.defaultProcess
        }
        if !list.filaments.contains(p.filament) {
            p.filament = list.defaultFilament.isEmpty ? list.filaments[0] : list.defaultFilament
        }
        set(p)
    }

    func select(process: String) { var p = profile; p.process = process; set(p) }
    func select(filament: String) { var p = profile; p.filament = filament; set(p) }

    /// Preset lists for a printer, off the main thread (parsing the vendor profiles takes ~1 s).
    func presets(for printer: String) async -> SCPresetList? {
        if let cached = cache[printer] { return cached }
        let list = await Task.detached(priority: .userInitiated) {
            SCSlicer.presets(forPrinter: printer)
        }.value
        if !list.printers.contains(printer) {
            error = "Stampante sconosciuta: \(printer)"
            return nil
        }
        cache[printer] = list
        return list
    }

    private func set(_ p: SliceProfile) {
        profile = p
        defaults.set(["printer": p.printer, "process": p.process, "filament": p.filament], forKey: Self.key)
    }

    /// "Bambu Lab P1S" -> [P1S 0.2, 0.4, 0.6, 0.8 nozzle]
    private static func groupPrinters(_ names: [String], models: [String]) -> [PresetGroup] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for (i, name) in names.enumerated() {
            let model = i < models.count && !models[i].isEmpty ? models[i] : "Altro"
            if groups[model] == nil { order.append(model) }
            groups[model, default: []].append(name)
        }
        return order.map { PresetGroup(id: $0, names: groups[$0]!) }
    }

    /// Groups filaments by brand (first word: Bambu, Generic, PolyLite, ...), Bambu first.
    private static func groupFilaments(_ names: [String]) -> [PresetGroup] {
        var groups: [String: [String]] = [:]
        for name in names {
            let brand = name.split(separator: " ").first.map(String.init) ?? "Altro"
            groups[brand, default: []].append(name)
        }
        let order = groups.keys.sorted { a, b in
            let rank = { (s: String) in s == "Bambu" ? 0 : s == "Generic" ? 1 : 2 }
            return (rank(a), a) < (rank(b), b)
        }
        return order.map { PresetGroup(id: $0, names: groups[$0]!) }
    }
}
