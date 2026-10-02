import Foundation
import simd

/// Which world axis points up.
///
/// Scanned data is overwhelmingly Z-up: the ASPRS LAS spec mandates it, and
/// survey XYZ follows the same convention. Graphics cameras conventionally use
/// Y-up, and this one did - so every LiDAR scan loaded lying on its side and
/// orbited around the wrong axis. The two conventions are now reconciled
/// explicitly rather than by accident.
enum UpAxis: Int, CaseIterable, Identifiable, Hashable {
    case y = 0
    case z = 1

    var id: Int { rawValue }
    var vector: SIMD3<Float> { self == .y ? [0, 1, 0] : [0, 0, 1] }
    var label: String { self == .y ? "Y" : "Z" }

    var next: UpAxis { self == .y ? .z : .y }
}

/// Arcball camera with smooth inertia for cinematic navigation
final class Camera {
    // MARK: - Properties

    /// Camera position in world space
    private(set) var position: SIMD3<Float> = [0, 0, 5]

    /// Point the camera looks at
    var target: SIMD3<Float> = [0, 0, 0]

    /// Which axis the camera orbits about. Also drives Height mode, so the
    /// colour ramp and the navigation always agree on which way is up.
    var upAxis: UpAxis = .z

    /// Up vector, valid even when looking straight along the up axis.
    ///
    /// A plan view looks directly down the up axis, which makes the
    /// conventional up vector parallel to the view direction - `lookAt` then
    /// divides by a zero-length cross product. The camera used to dodge this by
    /// clamping elevation to just short of the pole, which left every "top"
    /// view half a degree off square. Substituting a secondary axis at the pole
    /// gives exact 90-degree plans instead.
    var up: SIMD3<Float> {
        let primary = upAxis.vector
        let dir = position - target
        let len = length(dir)
        guard len > 0.0001 else { return primary }
        if abs(dot(dir / len, primary)) > 0.999 {
            // North up for a Z-up plan; Z up for a Y-up plan.
            return upAxis == .z ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
        }
        return primary
    }

    /// Field of view in radians
    var fov: Float = .pi / 4

    /// Near clipping plane
    var nearPlane: Float = 0.01

    /// Far clipping plane
    var farPlane: Float = 1000.0

    /// Distance from target (for orbit)
    private(set) var distance: Float = 5.0

    /// Orbit angles (azimuth, elevation)
    private var azimuth: Float = 0.3
    private var elevation: Float = 0.3

    /// Orientation applied to the model, as a quaternion.
    ///
    /// Held as a rotation rather than Euler angles because levelling composes
    /// an arbitrary axis-angle correction, which gimbals badly in XYZ order.
    private(set) var modelOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))

    // MARK: - Motion
    //
    // The camera follows a goal rather than carrying a velocity that decays.
    //
    // Decay alone only ever decelerates: motion begins at full speed the
    // instant a gesture starts, which is what made this feel abrupt. Following
    // a goal through a critically damped spring gives acceleration at the start
    // and settling at the end, with no overshoot - the difference between a
    // camera being shoved and a camera being moved.

    private var goalAzimuth: Float = 0.3
    private var goalElevation: Float = 0.3
    private var goalDistance: Float = 5.0
    private var goalTarget: SIMD3<Float> = [0, 0, 0]
    private var goalOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))

    private var vAzimuth: Float = 0
    private var vElevation: Float = 0
    private var vDistance: Float = 0
    private var vTarget: SIMD3<Float> = [0, 0, 0]

    /// Seconds to substantially close the gap. Longer reads as heavier and more
    /// deliberate; shorter as snappier. A quarter second is about the threshold
    /// where motion stops feeling mechanical.
    // Short enough to feel direct, long enough to take the step out of a
    // gesture. A quarter second read as lag; this reads as weight.
    private let smoothTime: Float = 0.085
    private let modelSmoothTime: Float = 0.075
    private let frameTime: Float = 1.0 / 60.0
    private let settleEpsilon: Float = 0.00015

    // Constraints
    private let minDistance: Float = 0.01
    private var maxDistance: Float = 10000.0  // Increased for large point clouds
    private let maxElevation: Float = .pi / 2 - 0.01

    // MARK: - Matrices

    var viewMatrix: simd_float4x4 {
        updatePosition()
        return simd_float4x4.lookAt(eye: position, target: target, up: up)
    }

    /// Exact pole for canonical views; free orbiting still clamps just short of
    /// it so that dragging past vertical does not flip the world over.
    private var standardViewElevation: Float { .pi / 2 }

    var modelMatrix: simd_float4x4 { simd_float4x4(modelOrientation) }

    /// Inverse of the model rotation, for mapping a world direction into model
    /// space - Height mode needs the up axis expressed where the points live.
    var inverseModelRotation: simd_float3x3 {
        simd_float3x3(modelOrientation.inverse)
    }

    /// The orientation the model is settling toward.
    ///
    /// Read this rather than `modelOrientation` when the answer has to be
    /// final: mid-move the two differ, and recomputing bounds against an angle
    /// the model is merely passing through would produce bounds it never has.
    var targetModelOrientation: simd_quatf { goalOrientation }

    /// Replace the orientation outright, rather than composing a delta onto it.
    /// Used to return the model to square. Routing through the goal keeps the
    /// same damping every other camera move gets.
    func setModelOrientation(_ orientation: simd_quatf) {
        goalOrientation = simd_normalize(orientation)
    }

    /// Compose an additional rotation onto the model.
    ///
    /// Left-multiplied, so the axis given is the world's rather than the
    /// model's - dragging the vertical handle turns the building about vertical
    /// however it is already tilted, which is the only behaviour that matches
    /// what the handle looks like it will do.
    func applyModelRotation(_ rotation: simd_quatf) {
        goalOrientation = simd_normalize(rotation * goalOrientation)
    }

    /// Orthographic when framing a canonical view, perspective otherwise.
    ///
    /// Plan and elevation views are only measurable without convergence, which
    /// is why every CAD package switches projection when you snap to one.
    /// Orbiting freely returns to perspective.
    private(set) var isOrthographic = false

    func projectionMatrix(aspectRatio: Float) -> simd_float4x4 {
        if isOrthographic {
            // Match the perspective framing at the focal distance, so switching
            // projection does not change how large the model appears.
            let height = distance * tan(fov * 0.5)
            return simd_float4x4.orthographic(halfHeight: height,
                                              aspectRatio: aspectRatio,
                                              nearPlane: -farPlane,
                                              farPlane: farPlane)
        }
        return simd_float4x4.perspective(fov: fov, aspectRatio: aspectRatio,
                                          nearPlane: nearPlane, farPlane: farPlane)
    }

    // MARK: - Canonical views

    enum StandardView: String, CaseIterable, Identifiable, Hashable {
        case top, front, side, iso
        var id: String { rawValue }
    }

    /// Snap to a canonical orientation. Angles are expressed relative to the
    /// current up axis, so a Z-up scan and a Y-up one both behave correctly.
    func setStandardView(_ view: StandardView) {
        switch view {
        case .top:
            goalAzimuth = 0
            goalElevation = standardViewElevation   // exactly straight down
        case .front:
            goalAzimuth = 0
            goalElevation = 0
        case .side:
            goalAzimuth = .pi / 2
            goalElevation = 0
        case .iso:
            goalAzimuth = .pi / 4
            goalElevation = .pi / 6
        }
        isOrthographic = view != .iso
    }

    /// Any free orbit leaves the canonical framing behind.
    private func leaveStandardView() {
        isOrthographic = false
    }

    // MARK: - Camera Control

    /// Orbit around target
    func orbit(deltaX: Float, deltaY: Float) {
        leaveStandardView()
        let sensitivity: Float = 0.005
        goalAzimuth += deltaX * sensitivity
        goalElevation = Swift.min(Swift.max(goalElevation + deltaY * sensitivity,
                                            -maxElevation), maxElevation)
    }

    /// Pan camera parallel to view plane
    func pan(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.002
        let forward = normalize(goalTarget - position)
        let right = normalize(cross(forward, up))
        let viewUp = cross(right, forward)
        let scale = goalDistance * 0.5
        goalTarget += right * (deltaX * sensitivity) * scale
        goalTarget += viewUp * (deltaY * sensitivity) * scale
    }

    /// Zoom in or out.
    ///
    /// Multiplicative, so a given gesture covers the same proportion of the
    /// scene whether you are looking at a whole site or a single bolt - and it
    /// can never cross zero.
    func zoom(delta: Float) {
        goalDistance = Swift.min(Swift.max(goalDistance * exp(-delta * 0.085),
                                           minDistance), maxDistance)
    }

    // MARK: - Model Rotation Control

    /// Rotate the model itself
    func rotateModel(deltaX: Float, deltaY: Float) {
        let sensitivity: Float = 0.008
        applyModelRotation(deltaX: deltaY * sensitivity, deltaY: deltaX * sensitivity)
    }

    /// Roll the model about the current view direction.
    func rollModel(by radians: Float) {
        let axis = normalize(position - target)
        guard axis.x.isFinite else { return }
        goalOrientation = simd_normalize(simd_quatf(angle: radians, axis: axis) * goalOrientation)
    }

    private func applyModelRotation(deltaX: Float, deltaY: Float) {
        // Pitch about world X, yaw about world Y, composed as quaternions.
        let pitch = simd_quatf(angle: deltaX, axis: SIMD3<Float>(1, 0, 0))
        let yaw = simd_quatf(angle: deltaY, axis: SIMD3<Float>(0, 1, 0))
        goalOrientation = simd_normalize(yaw * pitch * goalOrientation)
    }

    /// Reset model rotation only
    func resetModelRotation() {
        goalOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    }

    /// Reset camera to default view
    func reset() {
        goalAzimuth = 0.3
        goalElevation = 0.3
        goalDistance = 5.0
        goalTarget = [0, 0, 0]
        isOrthographic = false
        stopMotion()
        resetModelRotation()
    }

    /// Cancel inertia. Snapping to a view mid-glide should land, not drift.
    func stopMotion() {
        vAzimuth = 0; vElevation = 0; vDistance = 0
        vTarget = [0, 0, 0]
    }

    /// Land immediately on the goal, for load and for framing that should not
    /// be watched happening.
    func snapToGoal() {
        azimuth = goalAzimuth
        elevation = goalElevation
        distance = goalDistance
        target = goalTarget
        modelOrientation = goalOrientation
        stopMotion()
    }

    /// True while inertia is still being applied - used to pick the motion
    /// point budget over the still one.
    var isMoving: Bool {
        abs(azimuth - goalAzimuth) > settleEpsilon
            || abs(elevation - goalElevation) > settleEpsilon
            || abs(distance - goalDistance) > settleEpsilon * Swift.max(distance, 1)
            || length(target - goalTarget) > settleEpsilon * Swift.max(distance, 1)
            || simd_length(modelOrientation.vector - goalOrientation.vector) > settleEpsilon
    }

    /// Fit camera to view bounding box
    /// - Parameter preserveOrientation: keep the current azimuth/elevation and
    ///   only re-frame. Canonical views need this; without it, framing snapped
    ///   the camera back to a three-quarter angle immediately after the view
    ///   had been set.
    func fitToBounds(min: SIMD3<Float>, max: SIMD3<Float>, preserveOrientation: Bool = false) {
        let center = (min + max) * 0.5
        let size = max - min
        let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))

        goalTarget = center
        goalDistance = maxDim * 2.0

        if !preserveOrientation {
            // Nice 3/4 view
            goalAzimuth = .pi / 6
            goalElevation = .pi / 8
            isOrthographic = false
        }

        ppLog("Camera: fit to bounds, distance=\(distance), target=\(target)")
    }

    /// Critically damped follow: accelerates in, settles out, never overshoots.
    private func smoothDamp(_ current: Float, _ target: Float,
                            _ velocity: inout Float, _ time: Float) -> Float {
        let omega = 2 / max(time, 0.0001)
        let x = omega * frameTime
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = current - target
        let temp = (velocity + omega * change) * frameTime
        velocity = (velocity - omega * temp) * decay
        return target + (change + temp) * decay
    }

    /// Update with inertia (call every frame)
    func update() {
        azimuth = smoothDamp(azimuth, goalAzimuth, &vAzimuth, smoothTime)
        elevation = smoothDamp(elevation, goalElevation, &vElevation, smoothTime)
        distance = smoothDamp(distance, goalDistance, &vDistance, smoothTime)

        var tx = target.x, ty = target.y, tz = target.z
        var vx = vTarget.x, vy = vTarget.y, vz = vTarget.z
        tx = smoothDamp(tx, goalTarget.x, &vx, smoothTime)
        ty = smoothDamp(ty, goalTarget.y, &vy, smoothTime)
        tz = smoothDamp(tz, goalTarget.z, &vz, smoothTime)
        target = SIMD3<Float>(tx, ty, tz)
        vTarget = SIMD3<Float>(vx, vy, vz)

        // The model eases too, so levelling and manual rotation land rather
        // than jump.
        if simd_length(modelOrientation.vector - goalOrientation.vector) > settleEpsilon {
            let t = 1 - exp(-frameTime / modelSmoothTime)
            modelOrientation = simd_normalize(simd_slerp(modelOrientation, goalOrientation, t))
        }
    }

    // MARK: - Private




    private func updatePosition() {
        // Spherical to Cartesian, with elevation measured from the plane
        // perpendicular to the up axis.
        let horizontal = distance * cos(elevation)
        let vertical = distance * sin(elevation)
        let a = horizontal * sin(azimuth)
        let b = horizontal * cos(azimuth)

        switch upAxis {
        case .y: position = target + SIMD3<Float>(a, vertical, b)
        case .z: position = target + SIMD3<Float>(a, b, vertical)
        }
    }
}

// MARK: - Matrix Helpers

extension simd_float4x4 {
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)

        return simd_float4x4(
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        )
    }

    /// Creates a perspective projection matrix for Metal (z maps to [0, 1])
    static func perspective(fov: Float, aspectRatio: Float, nearPlane: Float, farPlane: Float) -> simd_float4x4 {
        let y = 1.0 / tan(fov * 0.5)
        let x = y / aspectRatio

        // Metal perspective matrix: maps z from [-near, -far] to [0, 1] in NDC
        // Row-major thinking, but constructed column-major:
        // clip.z = pos.z * (far/(near-far)) + pos.w * (near*far/(near-far))
        // clip.w = pos.z * (-1)
        // At pos.z = -near: clip.z = 0, clip.w = near -> ndc.z = 0
        // At pos.z = -far: clip.z = far, clip.w = far -> ndc.z = 1

        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, farPlane / (nearPlane - farPlane), -1),
            SIMD4<Float>(0, 0, (nearPlane * farPlane) / (nearPlane - farPlane), 0)
        )
    }

    /// Orthographic projection for Metal's [0, 1] depth range.
    static func orthographic(halfHeight: Float, aspectRatio: Float,
                             nearPlane: Float, farPlane: Float) -> simd_float4x4 {
        let h = max(halfHeight, 0.0001)
        let w = h * aspectRatio
        let zRange = farPlane - nearPlane
        return simd_float4x4(
            SIMD4<Float>(1 / w, 0, 0, 0),
            SIMD4<Float>(0, 1 / h, 0, 0),
            SIMD4<Float>(0, 0, -1 / zRange, 0),
            SIMD4<Float>(0, 0, -nearPlane / zRange, 1)
        )
    }

    static func identity() -> simd_float4x4 {
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle)
        let s = sin(angle)
        return simd_float4x4(
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}
