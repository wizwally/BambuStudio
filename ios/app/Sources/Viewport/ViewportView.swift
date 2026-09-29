import MetalKit
import SwiftUI

/// Observable state of the 3D view, shared by SwiftUI controls and the renderer.
@MainActor
final class ViewportState: ObservableObject {
    let renderer = ViewportRenderer()

    @Published var mode = ViewportRenderer.Mode.model { didSet { renderer?.mode = mode; redraw() } }
    @Published var lastLayer = 0 { didSet { renderer?.lastLayer = lastLayer; redraw() } }
    @Published var dimLowerLayers = false { didSet { renderer?.dimLowerLayers = dimLowerLayers; redraw() } }
    @Published private(set) var layerCount = 0
    @Published private(set) var hasModel = false
    @Published private(set) var roles: [Int] = []       // roles present in the toolpaths, for the legend

    fileprivate weak var view: MTKView?

    func redraw() { view?.setNeedsDisplay() }

    func show(mesh: SCMesh) {
        guard let renderer else { return }
        renderer.setToolpaths(nil)
        renderer.setMesh(mesh)
        renderer.resetCamera()
        hasModel = renderer.hasModel
        layerCount = 0
        roles = []
        mode = .model
    }

    func show(toolpaths: SCToolpaths?) {
        guard let renderer else { return }
        renderer.setToolpaths(toolpaths)
        layerCount = renderer.layerCount
        roles = Self.roles(in: toolpaths)
        lastLayer = max(layerCount - 1, 0)
        if layerCount > 0 { mode = .preview }
    }

    func resetCamera() {
        renderer?.resetCamera()
        redraw()
    }

    var layerLabel: String {
        guard let renderer, layerCount > 0 else { return "" }
        let z = renderer.layerZ[min(lastLayer, layerCount - 1)]
        return String(format: "Layer %d / %d · Z %.2f mm", lastLayer + 1, layerCount, z)
    }

    private static func roles(in toolpaths: SCToolpaths?) -> [Int] {
        guard let toolpaths else { return [] }
        var seen = Set<Int>()
        toolpaths.segments.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var i = 8
            while i < floats.count { seen.insert(Int(floats[i])); i += 9 }
        }
        return seen.sorted()
    }

    /// Same colours as kRoleColors in Shaders.metal.
    static func color(forRole role: Int) -> Color {
        let table: [(Double, Double, Double)] = [
            (0.90, 0.70, 0.70), (1.00, 0.90, 0.30), (1.00, 0.49, 0.22), (0.12, 0.12, 1.00),
            (0.69, 0.19, 0.16), (0.59, 0.33, 0.80), (0.90, 0.70, 0.70), (0.94, 0.25, 0.25),
            (0.40, 0.36, 0.78), (1.00, 0.55, 0.41), (0.30, 0.50, 0.73), (1.00, 1.00, 1.00),
            (0.00, 0.53, 0.43), (0.00, 0.23, 0.43), (0.00, 1.00, 0.00), (0.00, 0.50, 0.00),
            (0.00, 0.25, 0.00), (0.60, 1.00, 0.60), (0.70, 0.89, 0.67), (0.37, 0.82, 0.58),
            (0.85, 0.65, 0.95), (0.60, 0.60, 0.60),
        ]
        let c = table[min(max(role, 0), table.count - 1)]
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}

/// MTKView wrapper with touch, Pencil, trackpad and mouse navigation:
/// one-finger drag orbits, two-finger drag pans, pinch or scroll zooms, double tap resets.
struct MetalViewport: UIViewRepresentable {
    @ObservedObject var state: ViewportState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: state.renderer?.device)
        view.colorPixelFormat = ViewportRenderer.colorFormat
        view.depthStencilPixelFormat = ViewportRenderer.depthFormat
        view.sampleCount = ViewportRenderer.sampleCount
        view.clearColor = ViewportRenderer.background
        view.enableSetNeedsDisplay = true      // redraw only when something changes
        view.isPaused = true
        view.delegate = state.renderer
        state.view = view

        let c = context.coordinator
        let orbit = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.allowedScrollTypesMask = .all   // mouse wheel / trackpad scroll
        scroll.maximumNumberOfTouches = 0
        let reset = UITapGestureRecognizer(target: c, action: #selector(Coordinator.reset(_:)))
        reset.numberOfTapsRequired = 2
        for g in [orbit, pan, pinch, scroll, reset] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let state: ViewportState
        init(state: ViewportState) { self.state = state }

        private func consume(_ g: UIPanGestureRecognizer) -> CGPoint {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            return t
        }

        @objc func orbit(_ g: UIPanGestureRecognizer) {
            let t = consume(g)
            state.renderer?.camera.orbit(dx: Float(t.x), dy: Float(t.y))
            state.redraw()
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = consume(g)
            let h = Float(g.view?.bounds.height ?? 1)
            state.renderer?.camera.pan(dx: Float(t.x), dy: Float(t.y), viewHeight: h)
            state.redraw()
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            state.renderer?.camera.zoom(by: Float(g.scale))
            g.scale = 1
            state.redraw()
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let t = consume(g)
            state.renderer?.camera.zoom(by: Float(exp(t.y / 300)))
            state.redraw()
        }

        @objc func reset(_ g: UITapGestureRecognizer) {
            state.resetCamera()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true   // pinch + two-finger pan together
        }
    }
}

/// The 3D view with its overlay controls (mode, layer slider, legend).
struct ViewportPanel: View {
    @ObservedObject var state: ViewportState

    var body: some View {
        ZStack {
            MetalViewport(state: state)
                .ignoresSafeArea(edges: [.bottom])
            if state.renderer == nil {
                Text("Metal non disponibile").foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Picker("Vista", selection: $state.mode) {
                    Text("Modello").tag(ViewportRenderer.Mode.model)
                    Text("Anteprima").tag(ViewportRenderer.Mode.preview)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .disabled(state.layerCount == 0)
                Spacer()
                Button {
                    state.resetCamera()
                } label: {
                    Label("Centra", systemImage: "scope")
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if state.mode == .preview, !state.roles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.roles, id: \.self) { role in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ViewportState.color(forRole: role))
                                .frame(width: 14, height: 10)
                            Text(SCSlicer.roleName(role)).font(.caption2)
                        }
                    }
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 60)
                .padding(.trailing, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if state.mode == .preview, state.layerCount > 1 {
                VStack(spacing: 4) {
                    Text(state.layerLabel).font(.caption.monospacedDigit())
                    HStack {
                        Stepper("", value: $state.lastLayer, in: 0...(state.layerCount - 1))
                            .labelsHidden()
                        Slider(value: Binding(get: { Double(state.lastLayer) },
                                              set: { state.lastLayer = Int($0.rounded()) }),
                               in: 0...Double(state.layerCount - 1))
                        Toggle("Evidenzia layer", isOn: $state.dimLowerLayers)
                            .toggleStyle(.button)
                            .font(.caption)
                    }
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
        }
    }
}
