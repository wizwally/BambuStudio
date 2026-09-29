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

    let threads = ProcessInfo.processInfo.activeProcessorCount

    func bundledModel(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "stl", subdirectory: "TestModels")
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
                                maxThreads: threads) { pct, msg in
                Task { @MainActor in
                    self.percent = pct
                    self.message = msg
                }
            }
        }.value
        runs.insert(SliceRun(model: name, result: result), at: 0)
        if result.ok { lastGCode = URL(fileURLWithPath: result.gcodePath) }
        message = result.ok ? "Completato: \(name)" : "Errore: \(result.error)"
        busy = false
        return result
    }

    func sliceImported(_ url: URL) async {
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
        _ = await slice(local, name: url.lastPathComponent)
    }

    /// Headless run for `-autotest`: slices the bundled models, prints one
    /// "AUTOTEST {json}" line per model on stdout, then exits.
    func runAutotest() async {
        for name in ["cube20", "sphere_dense"] {
            guard let url = bundledModel(name) else {
                print("AUTOTEST {\"model\":\"\(name)\",\"ok\":false,\"error\":\"model not bundled\"}")
                continue
            }
            let r = await slice(url, name: name)
            let json: [String: Any] = [
                "model": name, "ok": r.ok, "error": r.error, "warning": r.warning,
                "threads": threads, "layers": r.layerCount,
                "load_s": r.loadSeconds, "slice_s": r.sliceSeconds, "export_s": r.exportSeconds,
                "peak_rss_mb": Double(r.peakRSSBytes) / 1_048_576,
                "est_print_min": r.estimatedPrintSeconds / 60,
                "gcode_bytes": (try? FileManager.default.attributesOfItem(atPath: r.gcodePath)[.size] as? Int) ?? 0,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print("AUTOTEST \(line)")
            }
        }
        fflush(stdout)
        exit(0)
    }
}

@main
struct SlicerPoCApp: App {
    @StateObject private var model = SliceModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
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
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Profilo") {
                    LabeledContent("Stampante", value: Profiles.printer)
                    LabeledContent("Processo", value: Profiles.process)
                    LabeledContent("Filamento", value: Profiles.filament)
                    LabeledContent("Thread", value: "\(model.threads)")
                }
                Section("Slice") {
                    Button("Cubo 20 mm") { start("cube20") }
                    Button("Sfera densa (~200k triangoli)") { start("sphere_dense") }
                    Button("Importa STL / 3MF…") { importing = true }
                }
                .disabled(model.busy)
                Section("Stato") {
                    if model.busy { ProgressView(value: Double(model.percent), total: 100) }
                    Text(model.message).font(.callout)
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
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "stl") ?? .data,
                                            UTType(filenameExtension: "3mf") ?? .data]) { result in
            if case .success(let url) = result {
                Task { await model.sliceImported(url) }
            }
        }
    }

    private func start(_ name: String) {
        guard let url = model.bundledModel(name) else {
            model.message = "Modello \(name) non incluso nell'app"
            return
        }
        Task { _ = await model.slice(url, name: name) }
    }
}
