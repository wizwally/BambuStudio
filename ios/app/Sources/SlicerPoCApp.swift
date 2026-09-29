import SwiftUI
import UniformTypeIdentifiers

// Fixed profiles for the PoC: Gualti's Bambu Lab P1S, 0.4 nozzle, PLA Basic.
enum Profiles {
    static let printer = "Bambu Lab P1S 0.4 nozzle"
    static let process = "0.20mm Standard @BBL X1C"
    static let filament = "Bambu PLA Basic @BBL P1S 0.4 nozzle"
}

struct SliceRun: Identifiable {
    let id = UUID()
    let model: String
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

    let threads = ProcessInfo.processInfo.activeProcessorCount
    let viewport: ViewportState

    init(viewport: ViewportState) {
        self.viewport = viewport
    }

    func bundledModel(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "stl", subdirectory: "TestModels")
    }

    /// Loads the model into the 3D view, as it will be placed on the bed.
    func loadMesh(_ modelURL: URL, name: String) async -> SCMesh {
        message = "Caricamento \(name)…"
        let threads = self.threads
        let mesh = await Task.detached(priority: .userInitiated) {
            SCSlicer.loadMesh(atPath: modelURL.path, printer: Profiles.printer, process: Profiles.process,
                              filament: Profiles.filament, maxThreads: threads)
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

    func slice(_ modelURL: URL, name: String) async -> SCSliceResult {
        busy = true
        percent = 0
        message = "Slicing \(name)…"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent((name as NSString).deletingPathExtension + ".gcode")
        let threads = self.threads
        let result = await Task.detached(priority: .userInitiated) {
            SCSlicer.sliceModel(atPath: modelURL.path,
                                printer: Profiles.printer,
                                process: Profiles.process,
                                filament: Profiles.filament,
                                outputPath: out.path,
                                maxThreads: threads,
                                collectToolpaths: true) { pct, msg in
                Task { @MainActor in
                    self.percent = pct
                    self.message = msg
                }
            }
        }.value
        runs.insert(SliceRun(model: name, result: result), at: 0)
        if result.ok {
            lastGCode = URL(fileURLWithPath: result.gcodePath)
            viewport.show(toolpaths: result.toolpaths)
        }
        message = result.ok ? "Completato: \(name)" : "Errore: \(result.error)"
        busy = false
        return result
    }

    /// Model first (immediate feedback in the 3D view), then slicing and layer preview.
    func open(_ modelURL: URL, name: String) async {
        busy = true
        let mesh = await loadMesh(modelURL, name: name)
        if mesh.ok {
            _ = await slice(modelURL, name: name)
        }
        busy = false
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
        for name in ["cube20", "sphere_dense"] {
            guard let url = bundledModel(name) else {
                print("AUTOTEST {\"model\":\"\(name)\",\"ok\":false,\"error\":\"model not bundled\"}")
                continue
            }
            var json: [String: Any] = ["model": name, "threads": threads]

            let mesh = await loadMesh(url, name: name)
            json["mesh_ok"] = mesh.ok
            json["mesh_error"] = mesh.error
            json["mesh_triangles"] = mesh.triangleCount
            json["mesh_s"] = mesh.loadSeconds
            json["mesh_bbox"] = [mesh.minX, mesh.minY, mesh.minZ, mesh.maxX, mesh.maxY, mesh.maxZ]
            json["png_model"] = snapshot(mode: .model, to: tmp.appendingPathComponent("autotest_\(name)_model.png"))

            let r = await slice(url, name: name)
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
            json["png_preview"] = snapshot(mode: .preview, to: tmp.appendingPathComponent("autotest_\(name)_preview.png"))
            if viewport.layerCount > 2 {
                viewport.lastLayer = viewport.layerCount / 2
                viewport.dimLowerLayers = true
                json["png_preview_half"] = snapshot(mode: .preview,
                                                    to: tmp.appendingPathComponent("autotest_\(name)_preview_half.png"))
                viewport.dimLowerLayers = false
            }

            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print("AUTOTEST \(line)")
            }
        }
        fflush(stdout)
        exit(0)
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
    @StateObject private var model: SliceModel

    init() {
        let viewport = ViewportState()
        _viewport = StateObject(wrappedValue: viewport)
        _model = StateObject(wrappedValue: SliceModel(viewport: viewport))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewport)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("-autotest") {
                        await model.runAutotest()
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SliceModel
    @EnvironmentObject var viewport: ViewportState
    @State private var importing = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Profilo") {
                    LabeledContent("Stampante", value: Profiles.printer)
                    LabeledContent("Processo", value: Profiles.process)
                    LabeledContent("Filamento", value: Profiles.filament)
                    LabeledContent("Thread", value: "\(model.threads)")
                }
                Section("Modello") {
                    Button("Cubo 20 mm") { start("cube20") }
                    Button("Sfera densa (~200k triangoli)") { start("sphere_dense") }
                    Button("Importa STL / 3MF…") { importing = true }
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
