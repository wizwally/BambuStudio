import simd

/// Orbit camera around a target point, Z up (bed coordinates in mm).
struct OrbitCamera {
    var target = SIMD3<Float>(128, 128, 0)
    var yaw: Float = -.pi / 2 - 0.45       // around Z; -pi/2 = looking from the front (-Y)
    var pitch: Float = 0.62                // elevation above the bed plane
    var distance: Float = 420
    var fovY: Float = 40 * .pi / 180

    var eye: SIMD3<Float> {
        let c = cos(pitch)
        return target + distance * SIMD3(c * cos(yaw), c * sin(yaw), sin(pitch))
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        let near = max(distance * 0.01, 0.5)
        let far = distance * 20 + 1000
        return .perspective(fovY: fovY, aspect: aspect, near: near, far: far)
             * .lookAt(eye: eye, target: target, up: SIMD3(0, 0, 1))
    }

    /// Light slightly above and to the left of the camera, so faces keep some relief.
    var lightDirection: SIMD3<Float> {
        let toEye = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(toEye, SIMD3(0, 0, 1)))
        return simd_normalize(toEye + SIMD3(0, 0, 0.8) - right * 0.35)
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.45), 1.52)
    }

    /// Moves the target in the view plane; dx/dy in points, viewHeight in points.
    mutating func pan(dx: Float, dy: Float, viewHeight: Float) {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let mmPerPoint = 2 * distance * tan(fovY / 2) / max(viewHeight, 1)
        target += (-right * dx + up * dy) * mmPerPoint
    }

    mutating func zoom(by factor: Float) {
        distance = min(max(distance / factor, 5), 3000)
    }

    /// Frames a bounding box (keeps the current angles).
    mutating func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 10)
        distance = radius / sin(fovY / 2) * 1.15
    }
}

extension simd_float4x4 {
    /// Right-handed perspective projection with Metal's 0...1 depth range.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY / 2)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0),
                                       SIMD4(0, ys, 0, 0),
                                       SIMD4(0, 0, zs, -1),
                                       SIMD4(0, 0, zs * near, 0)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0),
                                       SIMD4(s.y, u.y, -f.y, 0),
                                       SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}
