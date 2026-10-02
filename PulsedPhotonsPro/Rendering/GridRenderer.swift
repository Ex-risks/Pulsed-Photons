import Metal
import simd

/// The ground grid: a world-fixed rule the model is read against.
///
/// Two decisions make it an instrument rather than decoration.
///
/// Its spacing is always a round number in the file's own units, chosen so the
/// lines land roughly 80pt apart at whatever zoom is current. That is why it
/// needs no control of its own beyond on and off, and why it reads the same on
/// a room and on a site.
///
/// And it does not rotate with the model. The model turns against it, which is
/// the whole point of pairing it with TURN: a building sitting at 23° to the
/// world axes produces a skewed plan, and the grid is what you square it to.
final class GridRenderer {

    /// Lines either side of centre. 200 cells at ~80pt is some 16,000pt across,
    /// always wider than any window - so the mesh only has to be rebuilt when
    /// the spacing changes, never as the camera moves.
    private static let linesEitherSide = 100

    /// Every fifth line is emphasised. That is what lets the eye count cells
    /// without every line being labelled.
    private static let majorEvery = 5

    private static let minorWeight: Float = 0.34

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var buffer: MTLBuffer?
    private var vertexCount = 0

    /// What the current mesh was built for. Nothing is rebuilt unless one of
    /// these changes, so a still frame costs a single draw call and no CPU.
    private var builtSpacing: Float = 0
    private var builtOrigin: SIMD3<Float> = .zero
    private var builtAxis: UpAxis = .z

    /// Current line spacing, in the file's own units. The bar states it.
    private(set) var spacing: Float = 0

    init?(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
          depthFormat: MTLPixelFormat) {
        self.device = device

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gridVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gridFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depthFormat

        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil,
              let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = pipeline

        // Drawn before the cloud, against a cleared buffer, so writing depth is
        // safe despite the blending - and it lets points in front of the ground
        // occlude it, which is what makes the grid read as a floor rather than
        // an overlay pasted on top.
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
        self.depthState = depthState
    }

    // MARK: - Spacing

    /// Snap to a 1-2-5 sequence, the same one the scale bar uses, so a grid
    /// cell and the bar beside it never disagree about what a round number is.
    static func niceSpacing(targetWorld: Float) -> Float {
        guard targetWorld.isFinite, targetWorld > 0 else { return 1 }
        let exponent = floor(log10(targetWorld))
        let base = targetWorld / pow(10, exponent)
        let nice: Float = base < 1.5 ? 1 : (base < 3.5 ? 2 : (base < 7.5 ? 5 : 10))
        return nice * pow(10, exponent)
    }

    // MARK: - Mesh

    /// Rebuild only when the spacing, the ground plane or the up axis changes.
    func update(spacing newSpacing: Float, groundCentre: SIMD3<Float>, upAxis: UpAxis) {
        guard newSpacing.isFinite, newSpacing > 0 else { return }

        // Snap the origin to the spacing, so lines stay put when the mesh is
        // rebuilt rather than sliding under the model.
        let (a, b) = Self.groundAxes(for: upAxis)
        let snapped = groundCentre
            - a * (dot(groundCentre, a).truncatingRemainder(dividingBy: newSpacing))
            - b * (dot(groundCentre, b).truncatingRemainder(dividingBy: newSpacing))

        guard newSpacing != builtSpacing
                || snapped != builtOrigin
                || upAxis != builtAxis else { return }

        builtSpacing = newSpacing
        builtOrigin = snapped
        builtAxis = upAxis
        spacing = newSpacing

        let n = Self.linesEitherSide
        let reach = Float(n) * newSpacing
        var vertices: [GridVertex] = []
        vertices.reserveCapacity((2 * n + 1) * 4)

        for i in -n...n {
            let offset = Float(i) * newSpacing
            let weight: Float = i % Self.majorEvery == 0 ? 1 : Self.minorWeight

            // One line of each family, so the two directions interleave in the
            // buffer and a single draw covers both.
            let alongB = snapped + a * offset
            vertices.append(GridVertex(position: alongB - b * reach, weight: weight))
            vertices.append(GridVertex(position: alongB + b * reach, weight: weight))

            let alongA = snapped + b * offset
            vertices.append(GridVertex(position: alongA - a * reach, weight: weight))
            vertices.append(GridVertex(position: alongA + a * reach, weight: weight))
        }

        vertexCount = vertices.count
        buffer = device.makeBuffer(bytes: vertices,
                                   length: MemoryLayout<GridVertex>.stride * vertices.count,
                                   options: .storageModeShared)
    }

    /// The two world axes spanning the ground plane, given which one is up.
    static func groundAxes(for upAxis: UpAxis) -> (SIMD3<Float>, SIMD3<Float>) {
        upAxis == .y ? ([1, 0, 0], [0, 0, 1]) : ([1, 0, 0], [0, 1, 0])
    }

    // MARK: - Draw

    func draw(encoder: MTLRenderCommandEncoder,
              viewProjection: simd_float4x4,
              color: SIMD4<Float>,
              fadeCentre: SIMD3<Float>,
              fadeRadius: Float) {
        guard let buffer = buffer, vertexCount > 0 else { return }

        var uniforms = GridUniforms()
        uniforms.viewProjection = viewProjection
        uniforms.lineColor = color
        uniforms.fadeCentre = fadeCentre
        uniforms.fadeRadius = fadeRadius

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(BufferIndexGridVertices.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GridUniforms>.stride,
                               index: Int(BufferIndexGridUniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GridUniforms>.stride,
                                 index: Int(BufferIndexGridUniforms.rawValue))
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
    }
}
