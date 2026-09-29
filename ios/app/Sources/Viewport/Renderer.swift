import MetalKit
import simd
import UIKit

/// Must match `Uniforms` in Shaders.metal.
struct Uniforms {
    var viewProj: simd_float4x4
    var eye: SIMD4<Float>
    var color: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Metal renderer for the bed, the model mesh and the toolpath preview.
/// Used both by the on-screen MTKView and for offscreen snapshots (autotest).
final class ViewportRenderer: NSObject, MTKViewDelegate {
    enum Mode { case model, preview }

    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float
    static let sampleCount = 4

    static let background = MTLClearColor(red: 0.90, green: 0.91, blue: 0.92, alpha: 1)
    static let bedColor = SIMD4<Float>(0.30, 0.31, 0.33, 1)
    static let gridColor = SIMD4<Float>(0.45, 0.46, 0.48, 1)
    static let modelColor = SIMD4<Float>(0.00, 0.68, 0.26, 1)    // Bambu green

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let meshPipeline: MTLRenderPipelineState
    private let flatPipeline: MTLRenderPipelineState
    private let toolpathPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    var camera = OrbitCamera()
    var mode = Mode.model
    /// Visible layer range (inclusive) for the preview.
    var firstLayer = 0
    var lastLayer = 0
    var dimLowerLayers = false

    private var meshBuffer: MTLBuffer?
    private var meshVertexCount = 0
    private var bedFill: MTLBuffer?
    private var bedFillCount = 0
    private var bedLines: MTLBuffer?
    private var bedLinesCount = 0
    private var segments: MTLBuffer?
    private(set) var layerFirst: [UInt32] = []
    private(set) var layerZ: [Float] = []
    private(set) var bedMin = SIMD3<Float>(0, 0, 0)
    private(set) var bedMax = SIMD3<Float>(256, 256, 0)
    private(set) var modelMin = SIMD3<Float>(0, 0, 0)
    private(set) var modelMax = SIMD3<Float>(0, 0, 0)

    var layerCount: Int { layerZ.count }
    var hasModel: Bool { meshVertexCount > 0 }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = Self.colorFormat
            d.depthAttachmentPixelFormat = Self.depthFormat
            d.rasterSampleCount = Self.sampleCount
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                print("Viewport: pipeline \(vertex)/\(fragment) failed: \(error)")
                return nil
            }
        }
        guard let mesh = pipeline("mesh_vertex", "lit_fragment"),
              let flat = pipeline("flat_vertex", "flat_fragment"),
              let toolpath = pipeline("toolpath_vertex", "lit_fragment") else { return nil }
        meshPipeline = mesh
        flatPipeline = flat
        toolpathPipeline = toolpath

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: ds) else { return nil }
        depthState = depth
        super.init()
        setBed(outline: [SIMD2(0, 0), SIMD2(256, 0), SIMD2(256, 256), SIMD2(0, 256)], height: 256)
        resetCamera()
    }

    // MARK: - Scene

    func setMesh(_ mesh: SCMesh) {
        let outline = mesh.bedOutline.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: SIMD2<Float>.self))
        }
        if outline.count >= 3 { setBed(outline: outline, height: mesh.bedHeight) }
        meshBuffer = mesh.vertices.isEmpty ? nil : mesh.vertices.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        meshVertexCount = meshBuffer == nil ? 0 : Int(mesh.triangleCount) * 3
        modelMin = SIMD3(mesh.minX, mesh.minY, mesh.minZ)
        modelMax = SIMD3(mesh.maxX, mesh.maxY, mesh.maxZ)
    }

    func setToolpaths(_ toolpaths: SCToolpaths?) {
        guard let toolpaths, toolpaths.segmentCount > 0 else {
            segments = nil
            layerFirst = []
            layerZ = []
            return
        }
        segments = toolpaths.segments.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
        layerFirst = toolpaths.layerFirst.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        layerZ = toolpaths.layerZ.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        firstLayer = 0
        lastLayer = max(layerZ.count - 1, 0)
    }

    func clearScene() {
        meshBuffer = nil
        meshVertexCount = 0
        setToolpaths(nil)
    }

    func resetCamera() {
        camera = OrbitCamera()
        if hasModel {
            // Frame the model, but never closer than a quarter of the bed.
            let center = (modelMin + modelMax) / 2
            let half = simd_max((modelMax - modelMin) / 2, SIMD3(repeating: (bedMax.x - bedMin.x) / 8))
            camera.frame(min: center - half, max: center + half)
        } else {
            camera.frame(min: bedMin, max: bedMax + SIMD3(0, 0, 20))
        }
    }

    private func setBed(outline: [SIMD2<Float>], height: Float) {
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in outline { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        bedMin = SIMD3(lo, 0)
        bedMax = SIMD3(hi, height)

        // Plate: triangle fan (printable areas are convex), just below z = 0.
        var fill: [Float] = []
        let z: Float = -0.08
        for i in 1..<(outline.count - 1) {
            for p in [outline[0], outline[i], outline[i + 1]] { fill += [p.x, p.y, z] }
        }
        bedFill = device.makeBuffer(bytes: fill, length: fill.count * 4, options: .storageModeShared)
        bedFillCount = fill.count / 3

        // Grid every 10 mm plus the outline, slightly above the plate.
        var lines: [Float] = []
        let gz: Float = -0.04
        var x = (lo.x / 10).rounded(.up) * 10
        while x <= hi.x { lines += [x, lo.y, gz, x, hi.y, gz]; x += 10 }
        var y = (lo.y / 10).rounded(.up) * 10
        while y <= hi.y { lines += [lo.x, y, gz, hi.x, y, gz]; y += 10 }
        for i in 0..<outline.count {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            lines += [a.x, a.y, gz, b.x, b.y, gz]
        }
        bedLines = device.makeBuffer(bytes: lines, length: lines.count * 4, options: .storageModeShared)
        bedLinesCount = lines.count / 3
    }

    // MARK: - Drawing

    private func uniforms(aspect: Float, color: SIMD4<Float>) -> Uniforms {
        let top = layerZ.isEmpty ? 0 : layerZ[min(max(lastLayer, 0), layerZ.count - 1)]
        return Uniforms(viewProj: camera.viewProjection(aspect: aspect),
                        eye: SIMD4(camera.eye, 1),
                        color: color,
                        lightDir: SIMD4(camera.lightDirection, 0),
                        params: SIMD4(top, dimLowerLayers ? 1 : 0, 0, 0))
    }

    private func encode(_ enc: MTLRenderCommandEncoder, aspect: Float) {
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)

        // Bed
        enc.setRenderPipelineState(flatPipeline)
        if let bedFill {
            var u = uniforms(aspect: aspect, color: Self.bedColor)
            enc.setVertexBuffer(bedFill, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bedFillCount)
        }
        if let bedLines {
            var u = uniforms(aspect: aspect, color: Self.gridColor)
            enc.setVertexBuffer(bedLines, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: bedLinesCount)
        }

        var u = uniforms(aspect: aspect, color: Self.modelColor)
        switch mode {
        case .model:
            guard let meshBuffer, meshVertexCount > 0 else { return }
            enc.setRenderPipelineState(meshPipeline)
            enc.setVertexBuffer(meshBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshVertexCount)
        case .preview:
            guard let segments, layerZ.count > 0 else { return }
            let lo = min(max(firstLayer, 0), layerZ.count - 1)
            let hi = min(max(lastLayer, lo), layerZ.count - 1)
            let begin = Int(layerFirst[lo])
            let end = Int(layerFirst[hi + 1])
            guard end > begin else { return }
            enc.setRenderPipelineState(toolpathPipeline)
            enc.setVertexBuffer(segments, offset: begin * 9 * MemoryLayout<Float>.size, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: end - begin)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        encode(enc, aspect: Float(size.width / max(size.height, 1)))
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Renders one frame offscreen (autotest, thumbnails). Blocking.
    func snapshot(width: Int, height: Int) -> UIImage? {
        func texture(_ format: MTLPixelFormat, samples: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = .renderTarget
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        let bytesPerRow = width * 4
        guard let msaa = texture(Self.colorFormat, samples: Self.sampleCount),
              let resolved = texture(Self.colorFormat, samples: 1),
              let depth = texture(Self.depthFormat, samples: Self.sampleCount),
              let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.background
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc, aspect: Float(width) / Float(height))
        enc.endEncoding()
        guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: readback.contents(), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image)
    }
}
