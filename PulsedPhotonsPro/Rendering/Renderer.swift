import MetalKit
import simd
import AppKit
import UniformTypeIdentifiers

/// Diagnostic logging. Compiled out of release builds entirely.
///
/// Writes to stderr rather than stdout: stdout is block-buffered when it is not
/// a terminal, so launching the app from Finder or `open` silently swallowed
/// every message until the process exited.
@inline(__always)
func ppLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    FileHandle.standardError.write(Data((message() + "\n").utf8))
    #endif
}

/// Main Metal renderer for point cloud visualization
final class Renderer: NSObject, MTKViewDelegate {
    // MARK: - Theme

    // Deliberately no MSAA.
    //
    // Splats are round because the fragment shader discards outside the unit
    // circle, and `discard_fragment` rejects a whole fragment rather than
    // individual samples - so multisampling cannot soften that rim. Measured:
    // a splat edge showed 2 distinct tones at both sampleCount 1 and 4, while
    // analytic coverage in the shader gives 16 at sampleCount 1. MSAA was
    // therefore 4x the colour and depth memory plus a resolve, for nothing.
    // Revisit if non-point geometry (a scale bar, an axis indicator) is added.

    /// Single source of truth for the canvas colour. The live view and the
    /// image export both read from here so an export always matches the screen.
    /// Values come from Theme, so paper is defined in exactly one place.
    static func backgroundClearColor(isDarkMode: Bool) -> MTLClearColor {
        let p = isDarkMode ? Theme.paperDark : Theme.paperLight
        return MTLClearColor(red: p.x, green: p.y, blue: p.z, alpha: 1.0)
    }

    // MARK: - Properties

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState!
    /// Accumulating variants for Silhouette. Light accumulates on a dark
    /// ground; ink accumulates on paper, which is the same operation with the
    /// sign reversed.
    private var pipelineStateAddLight: MTLRenderPipelineState!
    private var pipelineStateAddInk: MTLRenderPipelineState!

    /// Depth-tested state for opaque modes, and a depth-disabled state for
    /// X-Ray. Both are built once; Metal state objects are immutable and must
    /// not be allocated per frame.
    private var depthStateTested: MTLDepthStencilState!
    private var depthStateDisabled: MTLDepthStencilState!

    // Buffers
    private var pointBuffer: MTLBuffer?
    private var pointCount: Int = 0

    // Point data management
    private(set) var originalVertices: [PointVertex] = []
    private var workingVertices: [PointVertex] = []
    private var currentSubsampleLevel: Float = 1.0

    // Display cap, in points.
    //
    // Measured on an M3 Pro at a 2400x1600 drawable with the real pipeline:
    // cost is linear in point count at ~4.5ns/point and almost independent of
    // point size, i.e. the limit is primitive rate, not fill rate or vertex
    // bandwidth (a 16-byte vertex renders no faster than the 48-byte one).
    //
    //     250K -> 0.87ms     2.5M -> 11.1ms     5M -> 23.2ms     10M -> 44ms
    //
    // 3M keeps a 16.67ms frame even at the largest point size, with headroom.
    //
    // That budget only binds while the camera is moving. Motion hides detail
    // anyway, and what matters is that the thing you are looking at when you
    // decide to export is what you will get - so once the camera settles the
    // view fills in to `stillBudget`.
    static let motionBudget: Int = 3_000_000

    /// How many points to *start* showing, derived from the machine.
    ///
    /// Not a hard limit and not tied to any particular Mac: it reads the
    /// physical memory of whatever it is running on, so a 128GB Mac Studio gets
    /// several times what a laptop does. A quarter of that, divided by the size
    /// of a vertex, and again by two - because until the storage refactor every
    /// displayed point is resident twice, once in `workingVertices` and once in
    /// the Metal buffer `uploadToGPU` copies it into.
    ///
    /// On 18GB that is ~49M points, or ~4.7GB across both copies.
    ///
    /// The POINTS control is free to go past this. Someone who knows their
    /// machine should not be argued with by an arbitrary fraction; the guard is
    /// `onBufferAllocationFailure`, which walks the budget back if the
    /// allocation actually fails, rather than a wall that refuses in advance.
    static let defaultDisplayPoints: Int = {
        let quarter = ProcessInfo.processInfo.physicalMemory / 4
        let perPoint = MemoryLayout<PointVertex>.stride * 2
        return max(1_000_000, Int(quarter) / perPoint)
    }()

    /// Points added per frame once the camera has settled.
    ///
    /// At the measured ~4.5ns a point this is ~9ms of work, so refinement never
    /// costs a frame. The whole cloud arrives over as many frames as it takes -
    /// 49M in about half a second - instead of one 220ms stall.
    static let stillBatch: Int = 2_000_000

    /// Largest 2D texture edge. Apple silicon allows 16384; asking for more is
    /// not an error Metal reports, it is one it aborts on.
    static let maxTextureSize = 16384

    /// Bytes the display buffer currently occupies.
    var displayBufferBytes: Int { pointCount * MemoryLayout<PointVertex>.stride }
    static let minimumDisplayPoints: Int = 10_000

    /// Reported when the display buffer cannot be allocated, so the budget can
    /// be walked back rather than leaving a stale view.
    var onBufferAllocationFailure: ((Int) -> Void)?

    /// Set by the view model while the pointer is driving the camera.
    var isInteracting: Bool = false

    /// Frames of stillness before the view fills in. At 60fps this is ~200ms:
    /// long enough not to thrash during a flick, short enough to feel immediate.
    private static let settleFrames = 12
    private var stillFrames = 0

    /// Points drawn this frame - a prefix of the display buffer while moving.
    private var drawCount: Int = 0

    // Selection.
    //
    // Held as a mask parallel to `workingVertices` - the editable set - rather
    // than as indices into the displayed subsample. See `selectionMask(in:)`.
    private(set) var selection: [Bool] = []
    private(set) var selectionCount: Int = 0

    // Camera
    let camera = Camera()

    // Settings
    var visualizationMode: VisualizationMode = .solid
    var pointSize: Float = 3.0
    /// 0 = opaque surface; above 0 the accumulating pipeline takes over.
    var overlayStrength: Float = 0.0

    /// Thickness of the section band, in world units along the up axis. Zero
    /// leaves the cloud whole. The band is centred on the camera's pivot, so
    /// the height is set by panning and the thickness by this.
    var sectionThickness: Float = 0.0

    /// Whether the ground grid is drawn.
    var showGrid: Bool = false

    private var gridRenderer: GridRenderer?

    /// Current grid spacing, in the file's own units. The bar states it, which
    /// is why the grid needs no control beyond on and off.
    var gridSpacing: Float { gridRenderer?.spacing ?? 0 }
    var pointColor: SIMD4<Float> = Theme.pointColor(isDarkMode: false)
    var isDarkMode: Bool = false

    // Bounds tracking
    private var minBounds: SIMD3<Float> = .zero
    private var maxBounds: SIMD3<Float> = .zero

    // View size for hit testing
    var viewSize: CGSize = .zero

    // MARK: - Initialization

    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            ppLog("ERROR: Metal is not supported on this device")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            ppLog("ERROR: Could not create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        super.init()

        metalView.device = device
        metalView.delegate = self
        metalView.clearColor = Renderer.backgroundClearColor(isDarkMode: isDarkMode)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.preferredFramesPerSecond = 60
        metalView.layer?.isOpaque = true
        // Progressive refinement blits its accumulation onto the drawable,
        // and a framebuffer-only texture cannot be a blit destination.
        metalView.framebufferOnly = false

        setupPipeline(metalView: metalView)
        setupDepthStates()

        ppLog("Renderer: initialized on \(device.name)")
    }

    // MARK: - Setup

    private func setupPipeline(metalView: MTKView) {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load Metal library")
        }

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            fatalError("Could not find shader functions")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = metalView.depthStencilPixelFormat

        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        gridRenderer = GridRenderer(device: device,
                                    library: library,
                                    pixelFormat: metalView.colorPixelFormat,
                                    depthFormat: metalView.depthStencilPixelFormat)

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

            // Accumulate light: destination + source. Density becomes
            // brightness, for a dark ground.
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineStateAddLight = try device.makeRenderPipelineState(descriptor: descriptor)

            // Accumulate ink: destination - source. The same quantum now
            // removes light, so marks darken paper. Additive blending on white
            // could only ever brighten it.
            descriptor.colorAttachments[0].rgbBlendOperation = .reverseSubtract
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineStateAddInk = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }
    }

    /// The overlay decides the blend, not the mode: any channel can be read as
    /// an opaque surface or as accumulating structure.
    private var accumulating: Bool { overlayStrength > 0 }

    private func currentPipeline() -> MTLRenderPipelineState {
        guard accumulating else { return pipelineState }
        return isDarkMode ? pipelineStateAddLight : pipelineStateAddInk
    }

    private func setupDepthStates() {
        let tested = MTLDepthStencilDescriptor()
        tested.depthCompareFunction = .less
        tested.isDepthWriteEnabled = true
        depthStateTested = device.makeDepthStencilState(descriptor: tested)

        let disabled = MTLDepthStencilDescriptor()
        disabled.depthCompareFunction = .always
        disabled.isDepthWriteEnabled = false
        depthStateDisabled = device.makeDepthStencilState(descriptor: disabled)
    }

    // MARK: - Point Cloud Loading

    func loadPointCloud(_ pointCloud: PointCloud, maxDisplayPoints: Int = Renderer.defaultDisplayPoints) {
        guard !pointCloud.vertices.isEmpty else {
            ppLog("ERROR: Point cloud has no vertices")
            return
        }

        originalVertices = pointCloud.vertices
        workingVertices = pointCloud.vertices
        clearSelection()

        // PointCloud computed these during parsing, off the main actor; there
        // is no reason to walk every vertex again here.
        minBounds = pointCloud.minBounds
        maxBounds = pointCloud.maxBounds

        // Adjust camera far plane based on point cloud size
        let size = maxBounds - minBounds
        let maxDim = max(size.x, max(size.y, size.z))
        camera.farPlane = max(1000.0, maxDim * 10.0)

        if workingVertices.count > maxDisplayPoints {
            currentSubsampleLevel = Float(maxDisplayPoints) / Float(workingVertices.count)
        } else {
            currentSubsampleLevel = 1.0
        }
        resubsampleAndUpload()

        camera.fitToBounds(min: minBounds, max: maxBounds)
        camera.snapToGoal()   // framing on load should not be watched happening

        worldOrigin = pointCloud.worldOrigin
        ppLog("Renderer: loaded \(pointCloud.pointCount) points, displaying \(pointCount)")
    }

    /// World-space position of the loaded scene's local origin.
    ///
    /// Kept so a second file can be re-based onto the first: every cloud stores
    /// its points relative to its own origin, so concatenating two arrays
    /// without this would stack unrelated scans on top of one another.
    private(set) var worldOrigin: SIMD3<Double> = .zero

    /// Add another cloud to the one already loaded.
    func appendPointCloud(_ cloud: PointCloud,
                          maxDisplayPoints: Int = Renderer.defaultDisplayPoints) {
        guard !cloud.vertices.isEmpty else { return }
        guard !originalVertices.isEmpty else {
            loadPointCloud(cloud, maxDisplayPoints: maxDisplayPoints)
            return
        }

        // Bring the incoming points into the frame the scene already uses. The
        // difference is taken in Double and only then narrowed, so a pair of
        // georeferenced scans kilometres apart still line up.
        let delta = cloud.worldOrigin - worldOrigin
        let shift = SIMD3<Float>(Float(delta.x), Float(delta.y), Float(delta.z))

        var incoming = cloud.vertices
        if shift != .zero {
            for i in 0..<incoming.count { incoming[i].position += shift }
        }

        originalVertices.append(contentsOf: incoming)
        workingVertices = originalVertices
        clearSelection()

        minBounds = simd_min(minBounds, cloud.minBounds + shift)
        maxBounds = simd_max(maxBounds, cloud.maxBounds + shift)

        let size = maxBounds - minBounds
        let maxDim = max(size.x, max(size.y, size.z))
        camera.farPlane = max(1000.0, maxDim * 10.0)

        if workingVertices.count > maxDisplayPoints {
            currentSubsampleLevel = Float(maxDisplayPoints) / Float(workingVertices.count)
        } else {
            currentSubsampleLevel = 1.0
        }
        resubsampleAndUpload()

        camera.fitToBounds(min: minBounds, max: maxBounds)
        camera.snapToGoal()

        ppLog("Renderer: added \(cloud.pointCount) points, scene now \(originalVertices.count)")
    }

    /// Empty the scene, leaving the sheet blank.
    ///
    /// Releases both copies of the cloud - the working array and the Metal
    /// buffer - so opening a large file after a larger one does not need room
    /// for the two of them at once.
    func unload() {
        originalVertices = []
        workingVertices = []
        pointBuffer = nil
        pointCount = 0
        drawCount = 0
        currentSubsampleLevel = 1.0
        selection = []
        selectionCount = 0
        minBounds = .zero
        maxBounds = .zero
        worldOrigin = .zero
        accumulated = 0
        accumCleared = false
        camera.setModelOrientation(simd_quatf(angle: 0, axis: [0, 0, 1]))
        ppLog("Renderer: unloaded")
    }

    private func uploadToGPU(_ vertices: [PointVertex]) {
        guard !vertices.isEmpty else {
            pointBuffer = nil
            pointCount = 0
            return
        }

        let dataSize = vertices.count * MemoryLayout<PointVertex>.stride

        guard let buffer = device.makeBuffer(bytes: vertices, length: dataSize, options: .storageModeShared) else {
            ppLog("ERROR: could not allocate \(dataSize / 1_048_576)MB for \(vertices.count) points")
            onBufferAllocationFailure?(vertices.count)
            return
        }

        self.pointBuffer = buffer
        self.pointCount = vertices.count
    }

    // MARK: - Subsampling

    /// Rebuild the GPU buffer from `workingVertices` at the current level.
    ///
    /// Callers that have mutated `workingVertices` must use this rather than
    /// `setSubsampleLevel`, which short-circuits when the level is unchanged.
    private func resubsampleAndUpload() {
        let target = targetCount(for: currentSubsampleLevel, of: workingVertices.count)
        uploadToGPU(Renderer.stratifiedSample(workingVertices, count: target))
    }

    func setSubsampleLevel(_ level: Float) {
        let newLevel = max(0.01, min(1.0, level))

        // Only recompute if level changed significantly
        guard abs(newLevel - currentSubsampleLevel) > 0.005 else { return }

        currentSubsampleLevel = newLevel
        resubsampleAndUpload()
    }

    // MARK: - Asynchronous resampling

    /// A snapshot of the editable point set. Arrays are copy-on-write, so this
    /// hands work to a background task without copying the storage.
    var displaySourceVertices: [PointVertex] { workingVertices }

    /// The up axis expressed in model space, so a quantity computed from raw
    /// vertex positions still measures height after the model has been levelled
    /// or turned.
    var modelSpaceUpAxis: SIMD3<Float> {
        simd_normalize(camera.inverseModelRotation * camera.upAxis.vector)
    }

    /// How many points a given slider level should produce, for a caller that
    /// will do the sampling itself off the main actor.
    func plannedCount(for level: Float) -> Int {
        targetCount(for: max(0.01, min(1.0, level)), of: workingVertices.count)
    }

    /// Install a display set computed elsewhere. Must be called on the main
    /// actor, since `draw(in:)` reads `pointBuffer` there.
    func applyDisplayVertices(_ vertices: [PointVertex], level: Float) {
        currentSubsampleLevel = max(0.01, min(1.0, level))
        uploadToGPU(vertices)
    }

    /// Select exactly `count` vertices, preserving their original order.
    ///
    /// Replaces a voxel-grid subsampler that derived cell size from bounding
    /// box *volume*. Real scans are surfaces, not solids, so that estimate was
    /// wrong by between 0.11x and 2x depending on topology - measured across
    /// sphere, terrain, facade and volumetric clouds. With the display cap now
    /// set from a frame-time budget, hitting the requested count exactly is a
    /// correctness requirement, not a nicety.
    ///
    /// Stratified rather than uniformly random: the sequence is divided into
    /// `count` equal buckets and one point is drawn from each. That is O(count)
    /// with no index array or sort, keeps the result ordered, and avoids the
    /// aliasing a fixed stride would hit on scan-line-ordered data.
    ///
    /// It also samples rather than averages. Voxel averaging synthesised points
    /// that appear nowhere in the source; every point shown here is a real
    /// measurement.
    ///
    /// Pure and thread-safe, so it can run off the main actor.
    nonisolated static func stratifiedSample(_ vertices: [PointVertex], count: Int) -> [PointVertex] {
        let n = vertices.count
        guard count > 0, n > 0 else { return [] }

        // Deterministic PRNG: re-sampling the same cloud gives the same points,
        // so draw order is stable and blended output does not shimmer.
        var state: UInt64 = 0x9E3779B97F4A7C15
        @inline(__always) func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }

        var result: [PointVertex]
        if count >= n {
            result = vertices
        } else {
            result = []
            result.reserveCapacity(count)
            for bucket in 0..<count {
                let lo = bucket * n / count
                let hi = (bucket + 1) * n / count      // exclusive
                let width = hi - lo
                let idx = width > 1 ? lo + Int(next() % UInt64(width)) : lo
                result.append(vertices[min(idx, n - 1)])
            }
        }

        // Shuffle, so that *any prefix* of the result is itself a uniform
        // sample of the cloud.
        //
        // This is what lets the motion budget cost nothing: instead of
        // re-uploading a smaller buffer every time the camera starts moving -
        // hundreds of megabytes, tens of milliseconds - the draw call simply
        // takes fewer vertices from the front of the same buffer. Stratified
        // order alone would not do: its first 3M of 20M are the first 15% of
        // the cloud in space, not a sample of it.
        if result.count > 1 {
            for i in stride(from: result.count - 1, to: 0, by: -1) {
                result.swapAt(i, Int(next() % UInt64(i + 1)))
            }
        }

        return result
    }

    /// Points to display for a given ratio, always within the frame budget.
    private func targetCount(for level: Float, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        let scaled = (Float(total) * level).rounded()
        // `Int(_: Float)` traps on non-finite or out-of-range input, so never
        // narrow without checking - the same hazard class that took down
        // draw(in:) via an overflowing counter.
        guard scaled.isFinite, scaled > 0 else { return 1 }
        let requested = scaled >= Float(total) ? total : Int(scaled)
        // Deliberately not clamped to `defaultDisplayPoints`. That figure
        // chooses where to *start*; asking for more is the user's call, and it
        // is honoured up to everything that is loaded.
        return max(1, min(requested, total))
    }

    // MARK: - Selection

    /// The transform selection must agree with, matching what was rendered.
    func selectionTransform(aspectRatio: Float) -> simd_float4x4 {
        camera.projectionMatrix(aspectRatio: aspectRatio) * camera.viewMatrix * camera.modelMatrix
    }

    /// Mark every point of `vertices` falling inside `rect` on screen.
    ///
    /// Selection deliberately runs over the *editable* set, not the displayed
    /// subsample. Marking only the sampled points would mean a marquee deleted
    /// roughly `displayed/total` of the region and the rest reappeared on the
    /// next resample - the user asked for a region, not for a sample of one.
    ///
    /// This also retires a proximity fallback that mapped display points back
    /// to source points by searching within 2% of the model's largest
    /// dimension. That was O(selected x total), and it deleted every neighbour
    /// inside the radius rather than what was actually selected.
    ///
    /// One linear pass, pure and thread-safe so it can run off the main actor.
    nonisolated static func selectionMask(in rect: CGRect,
                                          vertices: [PointVertex],
                                          transform mvp: simd_float4x4,
                                          viewSize: CGSize) -> (mask: [Bool], count: Int) {
        guard !vertices.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return ([], 0) }

        // `rect` arrives in top-left origin coordinates; MetalView converts
        // from AppKit's bottom-left origin at the gesture boundary.
        let minX = Float(rect.minX / viewSize.width) * 2.0 - 1.0
        let maxX = Float(rect.maxX / viewSize.width) * 2.0 - 1.0
        let minY = 1.0 - Float(rect.maxY / viewSize.height) * 2.0
        let maxY = 1.0 - Float(rect.minY / viewSize.height) * 2.0

        var mask = [Bool](repeating: false, count: vertices.count)
        var count = 0

        vertices.withUnsafeBufferPointer { src in
            mask.withUnsafeMutableBufferPointer { dst in
                for i in 0..<src.count {
                    let p = src[i].position
                    let clip = mvp * SIMD4<Float>(p.x, p.y, p.z, 1.0)
                    guard clip.w > 0 else { continue }
                    let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
                    if ndcX >= minX && ndcX <= maxX && ndcY >= minY && ndcY <= maxY {
                        dst[i] = true
                        count += 1
                    }
                }
            }
        }

        return (mask, count)
    }

    /// Remove masked points. Single pass, exact.
    nonisolated static func removingMasked(_ mask: [Bool], from vertices: [PointVertex]) -> [PointVertex] {
        guard mask.count == vertices.count else { return vertices }
        var out = [PointVertex]()
        out.reserveCapacity(vertices.count)
        for i in 0..<vertices.count where !mask[i] {
            out.append(vertices[i])
        }
        return out
    }

    nonisolated static func bounds(of vertices: [PointVertex]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !vertices.isEmpty else { return (.zero, .zero) }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for v in vertices {
            lo = min(lo, v.position)
            hi = max(hi, v.position)
        }
        return (lo, hi)
    }

    /// Install a selection computed off the main actor.
    func applySelection(mask: [Bool], count: Int) {
        guard mask.count == workingVertices.count else { return }
        selection = mask
        selectionCount = count
        ppLog("Renderer: selected \(count) of \(workingVertices.count) points")
    }

    /// Install an edited point set computed off the main actor.
    func applyEdit(vertices: [PointVertex], min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        workingVertices = vertices
        minBounds = lo
        maxBounds = hi
        clearSelection()
        resubsampleAndUpload()
        ppLog("Renderer: edit applied, \(workingVertices.count) points remain")
    }

    func clearSelection() {
        selection = []
        selectionCount = 0
    }

    func restoreOriginal() {
        workingVertices = originalVertices
        clearSelection()
        (minBounds, maxBounds) = Renderer.bounds(of: workingVertices)

        // Re-apply the display cap rather than uploading every original point.
        if workingVertices.count > Renderer.defaultDisplayPoints {
            currentSubsampleLevel = Float(Renderer.defaultDisplayPoints) / Float(workingVertices.count)
        } else {
            currentSubsampleLevel = 1.0
        }
        resubsampleAndUpload()

        ppLog("Renderer: restored \(originalVertices.count) original points")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = size
    }

    /// Everything that can change what a frame looks like.
    ///
    /// Redraw is decided by comparing this against the last drawn frame rather
    /// than by hand-placed dirty flags. Flags rely on every mutation site
    /// remembering to set one; if the state that feeds the draw call is
    /// unchanged, the output is identical by construction.
    struct FrameState: Equatable {
        var mvp: simd_float4x4
        var pointColor: SIMD4<Float>
        var heightAxis: SIMD3<Float>
        var pointSize: Float
        var minHeight: Float
        var maxHeight: Float
        var opacity: Float
        var sectionCentre: Float
        var sectionHalf: Float
        var mode: Int32
        var useVertexColors: Int32
        var depthDisabled: Bool
        var additive: Bool
        var darkGround: Bool
        var showGrid: Bool
        var bufferID: ObjectIdentifier?
        var pointCount: Int
        var drawableWidth: Double
        var drawableHeight: Double
    }

    func frameState(drawableSize: CGSize) -> FrameState {
        let u = createUniforms(aspectRatio: Float(drawableSize.width / max(drawableSize.height, 1)))
        return FrameState(
            mvp: u.modelViewProjection,
            pointColor: u.pointColor,
            heightAxis: u.heightAxis,
            pointSize: u.pointSize,
            minHeight: u.minHeight,
            maxHeight: u.maxHeight,
            opacity: u.overlayStrength,
            sectionCentre: u.sectionCentre,
            sectionHalf: u.sectionHalf,
            mode: u.visualizationMode,
            useVertexColors: u.useVertexColors,
            depthDisabled: accumulating,
            additive: accumulating,
            darkGround: isDarkMode,
            showGrid: showGrid,
            bufferID: pointBuffer.map { ObjectIdentifier($0) },
            pointCount: pointCount,
            drawableWidth: Double(drawableSize.width),
            drawableHeight: Double(drawableSize.height)
        )
    }

    /// Redraw at least this often even when nothing changed, so that anything
    /// this model fails to capture self-heals within a second rather than
    /// leaving a permanently stale canvas.
    private static let idleHeartbeatFrames = 60

    private var lastFrameState: FrameState?

    /// Frames elapsed since the last encode, saturating at the heartbeat
    /// threshold. Only the comparison against that threshold matters, so
    /// clamping keeps the counter from growing without bound.
    private var framesSinceDraw = 0

    /// Encoded frames and total display-link callbacks, for diagnostics.
    private(set) var encodedFrames = 0
    private(set) var displayLinkFrames = 0

    func draw(in view: MTKView) {
        camera.update()   // inertia must keep decaying even on skipped frames
        viewSize = view.drawableSize
        displayLinkFrames += 1

        // Motion budget while the camera moves, still budget once it settles.
        // Counted here rather than behind the early-out so stillness accrues
        // even on skipped frames.
        let moving = isInteracting || camera.isMoving
        stillFrames = moving ? 0 : min(stillFrames + 1, Renderer.settleFrames)
        let reduced = stillFrames < Renderer.settleFrames

        // How many points this view is *meant* to show. While the camera moves
        // that is the motion budget; once still it is the whole cloud - reached
        // a batch at a time rather than in one stalling frame.
        let target = reduced ? min(Renderer.motionBudget, pointCount) : pointCount
        drawCount = target

        guard viewSize.width > 0, viewSize.height > 0 else { return }

        let state = frameState(drawableSize: viewSize)
        framesSinceDraw = min(framesSinceDraw + 1, Renderer.idleHeartbeatFrames)

        // Anything that changes the image invalidates what has been built up.
        // A *growing* target does not: the display buffer is a shuffled
        // stratified sample, so the points already drawn are exactly the prefix
        // the larger target starts with. Settling therefore continues from the
        // motion budget instead of starting the cloud again.
        if !prepareAccumulation(size: viewSize) || state != lastFrameState || accumulated > target {
            accumulated = 0
        }

        let refining = accumulated < target && pointCount > 0

        // A freshly made texture holds whatever was in that memory. Until it has
        // been cleared at least once it must not be shown - with no cloud
        // loaded nothing else would ever write to it, and the sheet came up as
        // uninitialised GPU memory rather than paper.
        let needsClear = !accumCleared

        // Bail out before touching the drawable: acquiring one without
        // presenting it stalls the pool.
        //
        // `lastFrameState` is nil until the first encode, so the first frame
        // can never match and always draws.
        if !refining && !needsClear && state == lastFrameState
            && framesSinceDraw < Renderer.idleHeartbeatFrames {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        if (refining || needsClear), let colour = accumColor, let depth = accumDepth {
            let batch = reduced ? (target - accumulated)
                               : min(Renderer.stillBatch, target - accumulated)
            let first = accumulated == 0

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colour
            pass.colorAttachments[0].loadAction = first ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = Renderer.backgroundClearColor(isDarkMode: isDarkMode)
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = first ? .clear : .load
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1.0

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                // The pass runs even with nothing to draw: its clear is what
                // makes the texture safe to show.
                if refining {
                    renderToEncoder(encoder, viewSize: viewSize,
                                    from: accumulated, count: batch, includeGrid: first)
                    accumulated += batch
                }
                encoder.endEncoding()
                accumCleared = true
            }
        }

        // Present whatever has been built so far, complete or not.
        if let drawable = view.currentDrawable, let colour = accumColor,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: colour.width, height: colour.height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()

        lastFrameState = state
        framesSinceDraw = 0
        encodedFrames += 1

        if encodedFrames == 1 {
            ppLog("Renderer: first frame encoded, drawable \(Int(viewSize.width))x\(Int(viewSize.height))")
        }

        let worldHeight = visibleWorldHeight
        if worldHeight.isFinite,
           abs(worldHeight - lastReportedWorldHeight) > lastReportedWorldHeight * 0.005 {
            lastReportedWorldHeight = worldHeight
            onVisibleWorldHeightChange?(worldHeight)
        }

        onFrameDrawn?()
    }

    /// Called after each encoded frame. Anything drawn in SwiftUI that has to
    /// track the camera - the dimension overlay - hangs off this; it fires only
    /// on frames that were actually drawn, so a still view stays still.
    var onFrameDrawn: (() -> Void)?

    func renderToEncoder(_ encoder: MTLRenderCommandEncoder, viewSize: CGSize) {
        renderToEncoder(encoder, viewSize: viewSize,
                        from: 0, count: min(max(drawCount, 1), pointCount), includeGrid: true)
    }

    /// Draw a slice of the display buffer.
    ///
    /// A slice rather than the whole thing, because a still frame at 49M points
    /// costs some 220ms in one go. Split across frames into a texture that
    /// survives between them, the picture sharpens over half a second and no
    /// single frame ever stalls.
    ///
    /// Valid as a partial view because the display buffer is a shuffled
    /// stratified sample: any prefix of it is itself a uniform sample of the
    /// cloud, so a half-finished frame looks like a sparser version of the
    /// finished one rather than half a model.
    func renderToEncoder(_ encoder: MTLRenderCommandEncoder, viewSize: CGSize,
                         from start: Int, count: Int, includeGrid: Bool) {
        guard let buffer = pointBuffer, pointCount > 0, viewSize.height > 0 else { return }
        let stride = MemoryLayout<PointVertex>.stride
        let begin = max(0, min(start, pointCount))
        let length = max(0, min(count, pointCount - begin))
        guard length > 0 else { return }

        let aspect = Float(viewSize.width / viewSize.height)

        // Ground first, so points standing in front of it occlude it and it
        // reads as a floor rather than a transparency laid over the drawing.
        if includeGrid { drawGrid(encoder: encoder, aspectRatio: aspect) }

        encoder.setRenderPipelineState(currentPipeline())
        encoder.setDepthStencilState(accumulating ? depthStateDisabled : depthStateTested)

        var uniforms = createUniforms(aspectRatio: aspect)

        // Offset the buffer rather than the vertex start, so the shader's
        // vertex_id stays zero-based for the slice.
        encoder.setVertexBuffer(buffer, offset: begin * stride,
                                index: Int(BufferIndexVertices.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))

        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: length)
    }

    // MARK: - Progressive refinement

    private var accumColor: MTLTexture?
    private var accumDepth: MTLTexture?
    private var accumSize: CGSize = .zero

    /// Points drawn into the accumulation so far.
    private var accumulated: Int = 0

    /// Whether the accumulation has been cleared since it was allocated.
    /// Until it has, its contents are undefined and must not reach the screen.
    private var accumCleared = false

    /// Allocate the accumulation targets, or reuse them when the size is
    /// unchanged. Returns false if they could not be made, in which case the
    /// caller falls back to starting again next frame.
    private func prepareAccumulation(size: CGSize) -> Bool {
        if accumColor != nil, accumDepth != nil, size == accumSize { return true }

        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return false }

        let colour = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colour.usage = [.renderTarget, .shaderRead]
        colour.storageMode = .private

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depth.usage = .renderTarget
        depth.storageMode = .private

        guard let c = device.makeTexture(descriptor: colour),
              let d = device.makeTexture(descriptor: depth) else {
            ppLog("ERROR: could not allocate \(width)x\(height) accumulation targets")
            return false
        }

        accumColor = c
        accumDepth = d
        accumSize = size
        accumulated = 0
        accumCleared = false
        return true
    }

    private func createUniforms(aspectRatio: Float) -> Uniforms {
        let mvp = camera.projectionMatrix(aspectRatio: aspectRatio)
            * camera.viewMatrix * camera.modelMatrix

        // Height range along the up axis. Taking min/max of the dot products
        // rather than dotting the bounds directly keeps this correct for a
        // negative axis direction.
        // The up axis expressed in model space, so Height still measures
        // height after the model has been levelled or rotated.
        let axis = simd_normalize(camera.inverseModelRotation * camera.upAxis.vector)
        let worldAxis = camera.upAxis.vector
        let a = dot(minBounds, worldAxis), b = dot(maxBounds, worldAxis)

        var uniforms = Uniforms()
        uniforms.modelViewProjection = mvp
        uniforms.pointColor = pointColor
        uniforms.heightAxis = axis
        uniforms.pointSize = pointSize
        uniforms.minHeight = Swift.min(a, b)
        uniforms.maxHeight = Swift.max(a, b)
        uniforms.overlayStrength = overlayStrength
        // The cut is centred on what the camera is looking at, so height is set
        // by panning and only the thickness needs a control of its own.
        uniforms.sectionCentre = dot(camera.target, worldAxis)
        uniforms.sectionHalf = sectionThickness * 0.5
        uniforms.darkGround = isDarkMode ? 1 : 0
        uniforms.visualizationMode = Int32(visualizationMode.rawValue)
        uniforms.useVertexColors = (visualizationMode == .rgb) ? 1 : 0

        return uniforms
    }

    /// The ground grid, at the model's base.
    ///
    /// Spacing is chosen so about ten cells span the viewport, which is why it
    /// reads the same on a room and on a valley and needs no control of its
    /// own. Expressing that target as a fraction of the visible world rather
    /// than a pixel count also keeps it independent of backing scale.
    private func drawGrid(encoder: MTLRenderCommandEncoder, aspectRatio: Float) {
        guard showGrid, let grid = gridRenderer else { return }

        let worldHeight = Float(visibleWorldHeight)
        guard worldHeight.isFinite, worldHeight > 0 else { return }

        let worldAxis = camera.upAxis.vector
        let spacing = GridRenderer.niceSpacing(targetWorld: worldHeight / 10)

        // The plane sits at the base of the model, which is where a floor is.
        let base = Swift.min(dot(minBounds, worldAxis), dot(maxBounds, worldAxis))
        let centre = (minBounds + maxBounds) * 0.5
        let ground = centre - worldAxis * (dot(centre, worldAxis) - base)
        grid.update(spacing: spacing, groundCentre: ground, upAxis: camera.upAxis)

        // No model matrix: the grid is the datum, and the model turns against
        // it rather than carrying it along.
        let viewProjection = camera.projectionMatrix(aspectRatio: aspectRatio) * camera.viewMatrix
        let target = camera.target
        let fadeCentre = target - worldAxis * (dot(target, worldAxis) - base)

        grid.draw(encoder: encoder,
                  viewProjection: viewProjection,
                  color: Theme.gridColor(isDarkMode: isDarkMode),
                  fadeCentre: fadeCentre,
                  fadeRadius: worldHeight * 1.1)
    }

    // MARK: - Scene handles
    //
    // The turn rings and the section plane are drawn in SwiftUI but belong to
    // the scene, so their geometry is produced here - once - and both the
    // drawing and the hit test read the same points. What you see is exactly
    // what you can grab.

    // MARK: - The turn gizmo
    //
    // Screen-sized, and parked in a corner.
    //
    // The handles used to be world-space rings drawn around the cloud at its own
    // scale. That is exactly backwards: zooming in is when you most want to line
    // a wall up, and it was the moment the rings grew past the edges of the
    // window and became unusable. A gizmo of constant size cannot do that, and
    // putting it out of the way means it never sits on top of the thing being
    // aligned.

    /// Unit vector of world axis `index`.
    static func worldAxis(_ index: Int) -> SIMD3<Float> {
        switch index {
        case 0: return [1, 0, 0]
        case 1: return [0, 1, 0]
        default: return [0, 0, 1]
        }
    }

    static let gizmoRadius: CGFloat = 30

    /// Rotation part of the view matrix. `simd_float4x4` has no direct 3x3
    /// slice, and the translation must not come along.
    private var viewRotation: simd_float3x3 {
        let m = camera.viewMatrix
        return simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                             SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                             SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// Bottom-right, clear of the bar and of the mount's own margin.
    static func gizmoCentre(viewSize: CGSize) -> CGPoint {
        CGPoint(x: viewSize.width - gizmoRadius - 44,
                y: viewSize.height - gizmoRadius - 92)
    }

    /// One ring of the gizmo, with the depth of each point alongside it.
    ///
    /// Oriented by the camera's rotation only - no translation, no perspective -
    /// so it reports which way the world is facing without inheriting the
    /// projection's scale. The depth is what lets the far half of each ring be
    /// drawn back, which is the only thing that makes three overlapping circles
    /// legible as a sphere rather than a knot.
    func gizmoRing(axis index: Int, viewSize: CGSize,
                   segments: Int = 96) -> [(point: CGPoint, depth: Float)] {
        var u = SIMD3<Float>(repeating: 0), v = SIMD3<Float>(repeating: 0)
        switch index {
        case 0: u = [0, 1, 0]; v = [0, 0, 1]
        case 1: u = [0, 0, 1]; v = [1, 0, 0]
        default: u = [1, 0, 0]; v = [0, 1, 0]
        }

        let rotation = viewRotation
        let centre = Renderer.gizmoCentre(viewSize: viewSize)
        let r = Renderer.gizmoRadius

        return (0...segments).map { step in
            let t = Float(step) / Float(segments) * 2 * .pi
            let eye = rotation * (u * cos(t) + v * sin(t))
            // Screen y runs down; view-space y runs up.
            return (CGPoint(x: centre.x + CGFloat(eye.x) * r,
                            y: centre.y - CGFloat(eye.y) * r),
                    eye.z)
        }
    }

    /// Which way a positive turn about `index` moves around the gizmo.
    ///
    /// Measured rather than derived: the apparent direction flips with whether
    /// the axis faces the eye, and again with the screen's inverted y. Rotating
    /// a probe by a hundredth of a radian and observing the result is correct
    /// for any camera, and cannot be got backwards.
    func gizmoScreenSign(axis index: Int, viewSize: CGSize) -> Float {
        let axis = Renderer.worldAxis(index)
        let probe = Renderer.worldAxis((index + 1) % 3)
        let turned = simd_quatf(angle: 0.01, axis: axis).act(probe)

        let rotation = viewRotation
        let a = rotation * probe, b = rotation * turned

        // atan2 with y negated, matching the screen mapping above.
        var delta = atan2(-b.y, b.x) - atan2(-a.y, a.x)
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta >= 0 ? 1 : -1
    }

    /// The two rectangles bounding the section band, in world space.
    ///
    /// Four corners each, on the model's horizontal footprint at the top and
    /// bottom of the cut. Showing both edges is what makes the thickness
    /// legible rather than just the height.
    func sectionQuads(viewSize: CGSize) -> [[CGPoint]] {
        guard sectionThickness > 0, pointCount > 0 else { return [] }

        let axis = camera.upAxis
        let worldAxis = axis.vector
        let centreHeight = dot(camera.target, worldAxis)
        let half = sectionThickness * 0.5

        return [centreHeight - half, centreHeight + half].compactMap { height in
            let corners: [SIMD3<Float>]
            if axis == .y {
                corners = [[minBounds.x, height, minBounds.z], [maxBounds.x, height, minBounds.z],
                           [maxBounds.x, height, maxBounds.z], [minBounds.x, height, maxBounds.z]]
            } else {
                corners = [[minBounds.x, minBounds.y, height], [maxBounds.x, minBounds.y, height],
                           [maxBounds.x, maxBounds.y, height], [minBounds.x, maxBounds.y, height]]
            }
            let projected = corners.compactMap { projectWorldToScreen($0, viewSize: viewSize) }
            return projected.count == 4 ? projected : nil
        }
    }

    /// Project a world-space point, with no model matrix.
    ///
    /// The grid, the handles and the section plane are all world-fixed data the
    /// model moves against, so none of them may be carried by its rotation.
    func projectWorldToScreen(_ world: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        return Renderer.project(world, with: worldViewProjection(viewSize: viewSize),
                                viewSize: viewSize)
    }

    private func worldViewProjection(viewSize: CGSize) -> simd_float4x4 {
        camera.projectionMatrix(aspectRatio: Float(viewSize.width / viewSize.height))
            * camera.viewMatrix
    }

    private static func project(_ world: SIMD3<Float>, with vp: simd_float4x4,
                                viewSize: CGSize) -> CGPoint? {
        let clip = vp * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard clip.w > 0 else { return nil }
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        return CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width,
                       y: CGFloat(0.5 - ndc.y * 0.5) * viewSize.height)
    }

    /// Project a world-space point into top-left-origin view coordinates.
    /// Returns nil when the point is behind the camera.
    func projectToScreen(_ world: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let mvp = selectionTransform(aspectRatio: Float(viewSize.width / viewSize.height))
        let clip = mvp * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard clip.w > 0 else { return nil }
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        return CGPoint(x: CGFloat((ndc.x + 1) * 0.5) * viewSize.width,
                       y: CGFloat((1 - ndc.y) * 0.5) * viewSize.height)
    }

    // MARK: - Levelling

    /// Find the dominant plane by RANSAC and return the rotation that brings
    /// its normal onto `up`.
    ///
    /// Scans are rarely level: a tripod on a slope, a handheld unit, a drone
    /// with attitude error. Everything downstream assumes ground is ground -
    /// Height mode, plan and elevation views, the extent readout - so the tilt
    /// has to come out of the data rather than be worked around by eye.
    ///
    /// Consensus over random triples rather than a least-squares fit to
    /// everything: a scan is mostly *not* ground, and least squares would be
    /// dragged off by walls, vegetation and roofs. RANSAC finds the largest
    /// agreeing subset and ignores the rest.
    ///
    /// Pure and thread-safe: call it off the main actor.
    nonisolated static func levellingRotation(for vertices: [PointVertex],
                                              up: SIMD3<Float>,
                                              extent: Float,
                                              iterations: Int = 300,
                                              sampleSize: Int = 60_000) -> simd_quatf? {
        let n = vertices.count
        guard n >= 3, extent > 0 else { return nil }

        var state: UInt64 = 0x2545F4914F6CDD1D
        @inline(__always) func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        @inline(__always) func pick(_ limit: Int) -> Int { Int(next() % UInt64(limit)) }

        // Work on a sample: consensus does not need every point, and this keeps
        // levelling instant on a 50M-point cloud.
        let stride = max(1, n / sampleSize)
        var sample = [SIMD3<Float>]()
        sample.reserveCapacity(min(sampleSize, n))
        var i = 0
        while i < n { sample.append(vertices[i].position); i += stride }
        guard sample.count >= 3 else { return nil }

        // A point is on the plane if within 0.4% of the model's size.
        let threshold = extent * 0.004
        var bestNormal = SIMD3<Float>(0, 0, 0)
        var bestOffset: Float = 0
        var bestScore = 0

        for _ in 0..<iterations {
            let a = sample[pick(sample.count)]
            let b = sample[pick(sample.count)]
            let c = sample[pick(sample.count)]
            var nrm = cross(b - a, c - a)
            let len = length(nrm)
            guard len > 1e-6 else { continue }
            nrm /= len

            // Only consider planes that could plausibly be ground; a wall would
            // otherwise win on a facade scan and level the building onto its side.
            guard abs(dot(nrm, up)) > 0.5 else { continue }

            let d = dot(nrm, a)
            var score = 0
            for p in sample where abs(dot(nrm, p) - d) < threshold { score += 1 }
            if score > bestScore {
                bestScore = score
                bestNormal = nrm
                bestOffset = d
            }
        }

        // Require a real consensus rather than accepting the best of a bad lot.
        guard bestScore > sample.count / 20 else { return nil }

        // Refine: least squares over the inliers only, via the smallest
        // principal component of their covariance.
        var inliers = [SIMD3<Float>]()
        for p in sample where abs(dot(bestNormal, p) - bestOffset) < threshold { inliers.append(p) }
        if inliers.count >= 3, let refined = smallestPrincipalAxis(of: inliers) {
            bestNormal = dot(refined, bestNormal) < 0 ? -refined : refined
        }

        // Point the normal upward, then rotate it onto the up axis.
        if dot(bestNormal, up) < 0 { bestNormal = -bestNormal }
        let axis = cross(bestNormal, up)
        let axisLength = length(axis)
        let angle = atan2(axisLength, dot(bestNormal, up))
        guard axisLength > 1e-6, angle > 1e-4 else { return nil }   // already level

        return simd_quatf(angle: angle, axis: axis / axisLength)
    }

    /// Eigenvector of the smallest eigenvalue of the covariance matrix - the
    /// direction of least variance, i.e. the plane normal. Found by inverse
    /// power iteration, which needs no eigen-decomposition.
    private nonisolated static func smallestPrincipalAxis(of points: [SIMD3<Float>]) -> SIMD3<Float>? {
        var mean = SIMD3<Float>(0, 0, 0)
        for p in points { mean += p }
        mean /= Float(points.count)

        var xx: Float = 0, xy: Float = 0, xz: Float = 0, yy: Float = 0, yz: Float = 0, zz: Float = 0
        for p in points {
            let d = p - mean
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }
        let cov = simd_float3x3(SIMD3(xx, xy, xz), SIMD3(xy, yy, yz), SIMD3(xz, yz, zz))

        // Largest eigenvalue bound, so (bound*I - cov) turns the smallest
        // eigenvector into the dominant one and power iteration finds it.
        let bound = xx + yy + zz
        let shifted = simd_float3x3(diagonal: SIMD3(repeating: bound)) - cov

        var v = SIMD3<Float>(0.5773, 0.5773, 0.5773)
        for _ in 0..<48 {
            let w = shifted * v
            let len = length(w)
            guard len > 1e-20 else { return nil }
            v = w / len
        }
        return v
    }

    /// Bounds of `vertices` after `rotation`, without moving any data.
    ///
    /// Levelling used to bake the rotation into the point array, which meant
    /// copying the entire cloud twice - several gigabytes on a large scan,
    /// before anything could complete. Carrying the rotation in the model
    /// matrix instead costs nothing per frame, and only the bounds have to be
    /// recomputed: one read-only pass, no allocation.
    nonisolated static func bounds(of vertices: [PointVertex],
                                   rotatedBy rotation: simd_quatf) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !vertices.isEmpty else { return (.zero, .zero) }
        let m = simd_float3x3(rotation)
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for v in vertices {
            let p = m * v.position
            lo = min(lo, p)
            hi = max(hi, p)
        }
        return (lo, hi)
    }

    /// Install a levelling rotation computed off the main actor.
    func applyLevelling(rotation: simd_quatf, min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        camera.applyModelRotation(rotation)
        minBounds = lo
        maxBounds = hi
        camera.fitToBounds(min: minBounds, max: maxBounds)
    }

    /// Set the model's orientation outright, from the TURN numerals.
    ///
    /// Deliberately does not reframe: turning a building to square it up should
    /// leave the view where it was, unlike levelling, which is a correction big
    /// enough that refitting is what you want.
    func setModelOrientation(_ orientation: simd_quatf) {
        camera.setModelOrientation(orientation)
    }

    /// Adopt bounds recomputed for the current orientation.
    ///
    /// Rotating the model changes its axis-aligned extent, which the height
    /// ramp, the depth range and the grid all read. The pass that produces
    /// these is O(n), so it is debounced rather than run per scrub tick.
    func adoptBounds(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        minBounds = lo
        maxBounds = hi
    }

    // MARK: - Streaming export

    /// Everything needed to render an image, captured on the main actor so the
    /// render itself can run on a background task.
    struct ExportJob {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let depthState: MTLDepthStencilState
        let vertices: [PointVertex]     // COW: the full editable cloud, not the display subset
        let uniforms: Uniforms
        let clearColor: MTLClearColor
        let width: Int
        let height: Int

        /// A prefix of the vertices. Valid as a uniform sample because the
        /// display set is shuffled at construction.
        func limited(to count: Int) -> ExportJob {
            ExportJob(device: device, queue: queue, pipeline: pipeline,
                      depthState: depthState,
                      vertices: Array(vertices.prefix(count)),
                      uniforms: uniforms, clearColor: clearColor,
                      width: width, height: height)
        }
    }

    /// Splats stay pixel-constant across export scales.
    ///
    /// Enlarging them with the image would give a bigger picture of the same
    /// information - magnification, not detail. Held constant, a 4x export
    /// samples the scene four times more finely in each axis, and the extra
    /// points streamed in resolve structure the screen cannot show.
    ///
    /// Tonal density is preserved for free on large clouds: the export draws
    /// roughly (total / displayed) times more points over (scale^2) times more
    /// pixels, and for a 50M-point scan at 4x those very nearly cancel. On a
    /// small cloud, where no extra points exist to draw, the same marks spread
    /// over more pixels and a Silhouette export reads fainter - `opacity` is
    /// the compensation.
    func makeExportJob(width: Int, height: Int) -> ExportJob {
        let u = createUniforms(aspectRatio: Float(width) / Float(max(height, 1)))
        return ExportJob(
            device: device,
            queue: commandQueue,
            pipeline: currentPipeline(),
            depthState: accumulating ? depthStateDisabled : depthStateTested,
            vertices: workingVertices,
            uniforms: u,
            clearColor: Renderer.backgroundClearColor(isDarkMode: isDarkMode),
            width: width,
            height: height
        )
    }

    /// Render every point in the cloud, in batches, into one image.
    ///
    /// The interactive view is capped at a frame-time budget because that
    /// is a frame-time budget; a still image has no such budget. Points are
    /// streamed through a single reusable buffer, so an export is bounded by
    /// time rather than by GPU memory - the depth buffer composites the batches
    /// exactly as one impossible n-point draw call would.
    ///
    /// Pure and thread-safe: call it off the main actor.
    nonisolated static func renderExport(_ job: ExportJob,
                                         batchSize: Int = 4_000_000,
                                         isCancelled: @escaping () -> Bool = { false },
                                         progress: @escaping (Double) -> Void) -> CGImage? {
        // Metal aborts the process on an invalid texture descriptor rather
        // than failing gracefully, so the size has to be checked before one is
        // ever constructed. 16384 is the 2D limit on Apple silicon.
        guard job.width > 0, job.height > 0,
              job.width <= Renderer.maxTextureSize,
              job.height <= Renderer.maxTextureSize else {
            return nil
        }

        func descriptor(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor()
            d.pixelFormat = format
            d.width = job.width
            d.height = job.height
            d.usage = .renderTarget
            d.storageMode = .private
            return d
        }

        let colorDescriptor = descriptor(.bgra8Unorm)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .managed

        guard let texture = job.device.makeTexture(descriptor: colorDescriptor),
              let depthTexture = job.device.makeTexture(descriptor: descriptor(.depth32Float)) else {
            return nil
        }

        let total = job.vertices.count
        let vertexStride = MemoryLayout<PointVertex>.stride
        let batch = max(1, min(batchSize, total))

        // One staging buffer, reused. Each batch is committed and waited on
        // before the next overwrites it.
        guard let staging = job.device.makeBuffer(length: batch * vertexStride, options: .storageModeShared) else {
            return nil
        }

        var uniforms = job.uniforms
        var offset = 0
        var first = true

        while offset < total {
            if isCancelled() { return nil }

            let count = min(batch, total - offset)
            job.vertices.withUnsafeBytes { src in
                staging.contents().copyMemory(from: src.baseAddress! + offset * vertexStride,
                                              byteCount: count * vertexStride)
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = first ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = job.clearColor
            pass.depthAttachment.texture = depthTexture
            pass.depthAttachment.loadAction = first ? .clear : .load
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1.0

            guard let cb = job.queue.makeCommandBuffer(),
                  let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }

            enc.setRenderPipelineState(job.pipeline)
            enc.setDepthStencilState(job.depthState)
            enc.setVertexBuffer(staging, offset: 0, index: Int(BufferIndexVertices.rawValue))
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()

            offset += count
            first = false
            progress(Double(offset) / Double(total))
        }

        // Bring the managed texture back to the CPU.
        guard let blitBuffer = job.queue.makeCommandBuffer(),
              let blit = blitBuffer.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        blitBuffer.commit()
        blitBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: job.width * job.height * 4)
        texture.getBytes(&pixels,
                         bytesPerRow: job.width * 4,
                         from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                         size: MTLSize(width: job.width, height: job.height, depth: 1)),
                         mipmapLevel: 0)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels.swapAt(i, i + 2)   // BGRA -> RGBA
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        return CGImage(width: job.width, height: job.height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: job.width * 4,
                       space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Stamp the signature and encode straight to disk.
    ///
    /// Deliberately avoids NSImage. `NSImage(size:flipped:)` measures in
    /// *points*, so `tiffRepresentation` rasterises at the display's backing
    /// scale - on a Retina Mac a 4x export (11736x7768) asked AppKit for a
    /// 23472x15536 bitmap, 364 megapixels, and failed. Drawing into a
    /// CGContext at exact pixel dimensions also avoids three full-size copies
    /// of the image (NSImage, TIFF Data, NSBitmapImageRep).
    ///
    /// Pure and thread-safe: call it off the main actor.
    nonisolated static func writeImage(_ image: CGImage,
                                       to url: URL,
                                       signature: String,
                                       markColor: NSColor,
                                       markScale: CGFloat) -> String? {
        let width = image.width, height = image.height

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "Could not allocate a \(width)x\(height) image"
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Bottom-right, scaled with the export so it holds the same weight.
        let mark = NSAttributedString(string: signature, attributes: [
            .font: NSFont.systemFont(ofSize: 9 * markScale, weight: .regular),
            .foregroundColor: markColor,
            .kern: 0.2 * markScale
        ])
        let markSize = mark.size()
        let inset = 16 * markScale

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        mark.draw(at: NSPoint(x: CGFloat(width) - markSize.width - inset, y: inset))

        NSGraphicsContext.current = previous

        guard let composed = context.makeImage() else {
            return "Could not compose the final image"
        }

        let ext = url.pathExtension.lowercased()
        let isJPEG = (ext == "jpg" || ext == "jpeg")
        let type = (isJPEG ? UTType.jpeg : UTType.png).identifier as CFString

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return "Could not open \(url.lastPathComponent) for writing"
        }
        let options: CFDictionary? = isJPEG
            ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, composed, options)

        guard CGImageDestinationFinalize(destination) else {
            return "Could not encode \(url.lastPathComponent)"
        }
        return nil
    }

    // MARK: - Public Accessors

    /// Bounding size of the editable cloud, in the file's own units.
    var boundsSize: SIMD3<Float> { maxBounds - minBounds }
    var boundsMin: SIMD3<Float> { minBounds }
    var boundsMax: SIMD3<Float> { maxBounds }

    /// World-space height of the view at the camera's focal distance.
    /// Independent of drawable resolution, so the scale bar can divide by its
    /// own height in points.
    var visibleWorldHeight: Double {
        Double(2 * camera.distance * tan(camera.fov * 0.5))
    }

    /// Called on the main thread when the visible world height moves
    /// materially - i.e. when the camera dollies. Drives the scale bar.
    var onVisibleWorldHeightChange: ((Double) -> Void)?
    private var lastReportedWorldHeight: Double = -1

    func totalPointCount() -> Int { pointCount }
    func originalPointCount() -> Int { originalVertices.count }
    func workingPointCount() -> Int { workingVertices.count }
    func currentLevel() -> Float { currentSubsampleLevel }

    func fitCameraToBounds(preserveOrientation: Bool = false) {
        camera.fitToBounds(min: minBounds, max: maxBounds,
                           preserveOrientation: preserveOrientation)
    }

    /// Clear model rotation and re-frame the cloud.
    ///
    /// `Camera.reset()` alone restores a hard-coded distance of 5 units, which
    /// loses the model entirely on anything larger than a desk-scale scan.
    func resetCamera() {
        camera.reset()
        camera.fitToBounds(min: minBounds, max: maxBounds)
    }

    /// Which axis is up, for both navigation and Height mode.
    var upAxis: UpAxis {
        get { camera.upAxis }
        set {
            guard newValue != camera.upAxis else { return }
            camera.upAxis = newValue
            // Re-frame: the old orbit angles describe a different orientation.
            camera.fitToBounds(min: minBounds, max: maxBounds)
        }
    }
}
