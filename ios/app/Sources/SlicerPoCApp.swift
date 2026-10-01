import SwiftUI
import UniformTypeIdentifiers

struct SliceRun: Identifiable {
    let id = UUID()
    let model: String
    let profile: SliceProfile
    let result: SCSliceResult

    var summary: String {
        guard result.ok else { return "Errore: \(result.error)" }
        let total = result.loadSeconds + result.sliceSeconds + result.exportSeconds
        return String(format: "%lu layer · %.1f s (slicing %.1f s) · RAM di picco %.0f MB · stampa stimata %.0f min",
                      result.layerCount, total, result.sliceSeconds,
                      Double(result.peakRSSBytes) / 1_048_576, result.estimatedPrintSeconds / 60)
    }
}

@MainActor
final class SliceModel: ObservableObject {
    @Published var busy = false
    @Published var percent = 0
    @Published var message = "Pronto"
    @Published var runs: [SliceRun] = []
    @Published var lastGCode: URL?
    @Published var meshInfo = ""
    /// Model shown in the viewport, re-sliced when the profile changes.
    @Published private(set) var current: (url: URL, name: String)?
    /// Profile used for the current preview.
    @Published private(set) var slicedProfile: SliceProfile?

    let threads = ProcessInfo.processInfo.activeProcessorCount
    let viewport: ViewportState
    let presets: PresetStore

    init(viewport: ViewportState, presets: PresetStore) {
        self.viewport = viewport
        self.presets = presets
    }

    func bundledModel(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "stl", subdirectory: "TestModels")
    }

    /// Loads the model into the 3D view, as it will be placed on the bed.
    func loadMesh(_ modelURL: URL, name: String, profile: SliceProfile) async -> SCMesh {
        message = "Caricamento \(name)…"
        let threads = self.threads
        let mesh = await Task.detached(priority: .userInitiated) {
            SCSlicer.loadMesh(atPath: modelURL.path, printer: profile.printer, process: profile.process,
                              filament: profile.filament, maxThreads: threads)
        }.value
        if mesh.ok {
            viewport.show(mesh: mesh)
            meshInfo = String(format: "%@ · %lu triangoli · %.1f × %.1f × %.1f mm", name, mesh.triangleCount,
                              mesh.maxX - mesh.minX, mesh.maxY - mesh.minY, mesh.maxZ - mesh.minZ)
        } else {
            message = "Errore: \(mesh.error)"
        }
        return mesh
    }

    func slice(_ modelURL: URL, name: String, profile: SliceProfile) async -> SCSliceResult {
        busy = true
        percent = 0
        message = "Slicing \(name)…"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent((name as NSString).deletingPathExtension + ".gcode")
        let threads = self.threads
        let result = await Task.detached(priority: .userInitiated) {
            SCSlicer.sliceModel(atPath: modelURL.path,
                                printer: profile.printer,
                                process: profile.process,
                                filament: profile.filament,
                                outputPath: out.path,
                                maxThreads: threads,
                                collectToolpaths: true) { pct, msg in
                Task { @MainActor in
                    self.percent = pct
                    self.message = msg
                }
            }
        }.value
        runs.insert(SliceRun(model: name, profile: profile, result: result), at: 0)
        if result.ok {
            lastGCode = URL(fileURLWithPath: result.gcodePath)
            viewport.show(toolpaths: result.toolpaths)
            slicedProfile = profile
        }
        message = result.ok ? "Completato: \(name)" : "Errore: \(result.error)"
        busy = false
        return result
    }

    /// Model first (immediate feedback in the 3D view), then slicing and layer preview.
    func open(_ modelURL: URL, name: String) async {
        busy = true
        current = (modelURL, name)
        slicedProfile = nil
        let profile = presets.profile
        let mesh = await loadMesh(modelURL, name: name, profile: profile)
        if mesh.ok {
            _ = await slice(modelURL, name: name, profile: profile)
        }
        busy = false
    }

    /// Reloads and re-slices the current model with the selected profile
    /// (another printer can change the bed and the placement).
    func reslice() async {
        guard let current else { return }
        await open(current.url, name: current.name)
    }

    var needsReslice: Bool {
        current != nil && slicedProfile != nil && slicedProfile != presets.profile
    }

    func openImported(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: local)
        do {
            try FileManager.default.copyItem(at: url, to: local)
        } catch {
            message = "Impossibile leggere il file: \(error.localizedDescription)"
            return
        }
        await open(local, name: url.lastPathComponent)
    }

    /// Headless run for `-autotest`: for each bundled model loads the mesh, slices it,
    /// renders the model and the preview offscreen (PNG in tmp/), prints one
    /// "AUTOTEST {json}" line per model on stdout, then exits.
    func runAutotest() async {
        let tmp = FileManager.default.temporaryDirectory

        // Preset lists: P1S (cold, then cached) and A1 mini defaults.
        var presetJSON: [String: Any] = ["test": "presets_p1s"]
        if let p1s = await presets.presets(for: SliceProfile.p1sDefault.printer) {
            presetJSON = ["test": "presets_p1s", "printers": p1s.printers.count, "processes": p1s.processes.count,
                          "filaments": p1s.filaments.count, "load_s": p1s.loadSeconds,
                          "default_process": p1s.defaultProcess, "default_filament": p1s.defaultFilament]
        }
        emit(presetJSON)

        var jobs: [(String, SliceProfile)] = [("cube20", .p1sDefault), ("sphere_dense", .p1sDefault)]
        let mini = "Bambu Lab A1 mini 0.4 nozzle"
        if let list = await presets.presets(for: mini) {
            jobs.append(("cube20", SliceProfile(printer: mini, process: list.defaultProcess, filament: list.defaultFilament)))
        } else {
            emit(["test": "presets_a1mini", "ok": false, "error": presets.error])
        }

        for (name, profile) in jobs {
            guard let url = bundledModel(name) else {
                print("AUTOTEST {\"model\":\"\(name)\",\"ok\":false,\"error\":\"model not bundled\"}")
                continue
            }
            let tag = profile == .p1sDefault ? name : name + "_a1mini"
            var json: [String: Any] = ["model": name, "threads": threads, "printer": profile.printer,
                                       "process": profile.process, "filament": profile.filament]

            let mesh = await loadMesh(url, name: name, profile: profile)
            json["mesh_ok"] = mesh.ok
            json["mesh_error"] = mesh.error
            json["mesh_triangles"] = mesh.triangleCount
            json["mesh_s"] = mesh.loadSeconds
            json["mesh_bbox"] = [mesh.minX, mesh.minY, mesh.minZ, mesh.maxX, mesh.maxY, mesh.maxZ]
            json["png_model"] = snapshot(mode: .model, to: tmp.appendingPathComponent("autotest_\(tag)_model.png"))

            let r = await slice(url, name: name, profile: profile)
            json["ok"] = r.ok
            json["error"] = r.error
            json["warning"] = r.warning
            json["layers"] = r.layerCount
            json["load_s"] = r.loadSeconds
            json["slice_s"] = r.sliceSeconds
            json["export_s"] = r.exportSeconds
            json["peak_rss_mb"] = Double(r.peakRSSBytes) / 1_048_576
            json["est_print_min"] = r.estimatedPrintSeconds / 60
            json["gcode_bytes"] = (try? FileManager.default.attributesOfItem(atPath: r.gcodePath)[.size] as? Int) ?? 0
            json["toolpath_segments"] = r.toolpaths?.segmentCount ?? 0
            json["toolpath_layers"] = r.toolpaths?.layerCount ?? 0
            json["png_preview"] = snapshot(mode: .preview, to: tmp.appendingPathComponent("autotest_\(tag)_preview.png"))
            if viewport.layerCount > 2 {
                viewport.lastLayer = viewport.layerCount / 2
                viewport.dimLowerLayers = true
                json["png_preview_half"] = snapshot(mode: .preview,
                                                    to: tmp.appendingPathComponent("autotest_\(tag)_preview_half.png"))
                viewport.dimLowerLayers = false
            }

            emit(json)
        }
        fflush(stdout)
        exit(0)
    }

    private func emit(_ json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("AUTOTEST \(line)")
        }
    }

    private func snapshot(mode: ViewportRenderer.Mode, to url: URL) -> String {
        guard let renderer = viewport.renderer else { return "error: no Metal device" }
        renderer.mode = mode
        guard let image = renderer.snapshot(width: 1024, height: 768), let png = image.pngData() else {
            return "error: snapshot failed"
        }
        do { try png.write(to: url) } catch { return "error: \(error.localizedDescription)" }
        return url.lastPathComponent
    }
}

@main
struct SlicerPoCApp: App {
    @StateObject private var viewport: ViewportState
    @StateObject private var presets: PresetStore
    @StateObject private var model: SliceModel
    @StateObject private var printer = PrinterConnection()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let viewport = ViewportState()
        let presets = PresetStore()
        _viewport = StateObject(wrappedValue: viewport)
        _presets = StateObject(wrappedValue: presets)
        _model = StateObject(wrappedValue: SliceModel(viewport: viewport, presets: presets))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewport)
                .environmentObject(presets)
                .environmentObject(printer)
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-printertest"), args.count > i + 3 {
                        await PrinterAutotest.run(printer, host: args[i + 1], serial: args[i + 2], code: args[i + 3])
                    } else if args.contains("-autotest") {
                        await model.runAutotest()
                    } else {
                        await presets.load()
                        if printer.hasConfiguration { printer.connect() }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { printer.resume() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SliceModel
    @EnvironmentObject var viewport: ViewportState
    @EnvironmentObject var presets: PresetStore
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            List {
                ProfileSection()
                    .disabled(model.busy)
                Section("Stampante") {
                    PrinterSummaryRow()
                }
                Section("Modello") {
                    Button("Cubo 20 mm") { start("cube20") }
                    Button("Sfera densa (~200k triangoli)") { start("sphere_dense") }
                    Button("Importa STL / 3MF…") { importing = true }
                    if model.needsReslice {
                        Button {
                            Task { await model.reslice() }
                        } label: {
                            Label("Affetta di nuovo con il profilo scelto", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .disabled(model.busy)
                Section("Stato") {
                    if model.busy { ProgressView(value: Double(model.percent), total: 100) }
                    Text(model.message).font(.callout)
                    if !model.meshInfo.isEmpty { Text(model.meshInfo).font(.caption).foregroundStyle(.secondary) }
                    if let gcode = model.lastGCode {
                        ShareLink(item: gcode) { Label("Condividi G-code", systemImage: "square.and.arrow.up") }
                    }
                }
                Section("Risultati") {
                    ForEach(model.runs) { run in
                        VStack(alignment: .leading) {
                            Text(run.model).font(.headline)
                            Text("\(run.profile.printer) · \(run.profile.process)").font(.caption2).foregroundStyle(.secondary)
                            Text(run.summary).font(.caption).foregroundStyle(run.result.ok ? Color.primary : Color.red)
                        }
                    }
                }
            }
            .navigationTitle("Slicer PoC")
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            ViewportPanel(state: viewport)
                .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "stl") ?? .data,
                                            UTType(filenameExtension: "3mf") ?? .data]) { result in
            if case .success(let url) = result {
                Task { await model.openImported(url) }
            }
        }
    }

    private func start(_ name: String) {
        guard let url = model.bundledModel(name) else {
            model.message = "Modello \(name) non incluso nell'app"
            return
        }
        Task { await model.open(url, name: name) }
    }
}

/// Printer / process / filament pickers, fed by PresetStore.
struct ProfileSection: View {
    @EnvironmentObject var presets: PresetStore
    @EnvironmentObject var model: SliceModel

    var body: some View {
        Section {
            Picker("Stampante", selection: Binding(get: { presets.profile.printer },
                                                   set: { p in Task { await presets.select(printer: p) } })) {
                ForEach(presets.printerGroups) { group in
                    Section(group.id) {
                        ForEach(group.names, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .pickerStyle(.navigationLink)

            Picker("Processo", selection: Binding(get: { presets.profile.process },
                                                  set: { presets.select(process: $0) })) {
                ForEach(presets.processes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)

            Picker("Filamento", selection: Binding(get: { presets.profile.filament },
                                                   set: { presets.select(filament: $0) })) {
                ForEach(presets.filamentGroups) { group in
                    Section(group.id) {
                        ForEach(group.names, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .pickerStyle(.navigationLink)

            LabeledContent("Thread", value: "\(model.threads)")
        } header: {
            HStack {
                Text("Profilo")
                if presets.loading { ProgressView().controlSize(.small) }
            }
        } footer: {
            if !presets.error.isEmpty { Text(presets.error).foregroundStyle(.red) }
        }
    }
}

/// `-printertest <host> <serial> <code>`: connects to a printer (or ios/tools/fake_printer.py),
/// waits for status reports, prints one "AUTOTEST {json}" line and exits.
@MainActor
enum PrinterAutotest {
    static func run(_ printer: PrinterConnection, host: String, serial: String, code: String) async {
        let start = Date()
        printer.connectForTest(host: host, serial: serial, accessCode: code)
        var firstStatus: Double?
        var percentAtFirst: Int?
        // Up to 15 s: first full report, then at least two incremental updates.
        while Date().timeIntervalSince(start) < 15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if case .failed = printer.state { break }
            if !printer.status.isEmpty, firstStatus == nil {
                firstStatus = Date().timeIntervalSince(start)
                percentAtFirst = printer.status.percent
            }
            if firstStatus != nil, printer.messageCount >= 3, printer.status.percent != percentAtFirst { break }
        }
        let s = printer.status
        var json: [String: Any] = [
            "test": "printer", "state": printer.state.label, "connected": printer.state == .connected,
            "messages": printer.messageCount, "first_status_s": firstStatus ?? -1,
            "gcode_state": s.gcodeState, "job": s.jobName, "percent_first": percentAtFirst ?? -1,
            "percent": s.percent ?? -1, "layer": s.layer ?? -1, "total_layers": s.totalLayers ?? -1,
            "remaining_min": s.remainingMinutes ?? -1, "nozzle": s.nozzle ?? -1, "nozzle_target": s.nozzleTarget ?? -1,
            "bed": s.bed ?? -1, "part_fan": s.partFan ?? -1, "firmware": s.firmware,
            "trays": s.trays.map { "\($0.id):\($0.type)\($0.active ? "*" : "")" },
            "cert_pinned": String(printer.pinnedCertificate?.prefix(16) ?? ""),
        ]
        // Second connection: the pinned certificate must be accepted again.
        printer.disconnect()
        printer.connect()
        let t2 = Date()
        while Date().timeIntervalSince(t2) < 5, printer.state != .connected {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if case .failed = printer.state { break }
        }
        json["reconnect_with_pin"] = printer.state == .connected
        printer.disconnect()
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("AUTOTEST \(line)")
        }
        fflush(stdout)
        exit(0)
    }
}
