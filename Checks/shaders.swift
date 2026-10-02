import Foundation
import Metal
import simd

// Exercises the real Shaders.metal - compiled from the project source, not a
// copy - for the two things that could silently do nothing:
//
//   1. SECTION culls by pushing clip z past w. If Metal does not clip point
//      primitives that way, the cut is a no-op (or worse, a blob at the origin).
//   2. The cut still applies when the overlay switches the pipeline from
//      painting a surface to accumulating density.

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

let libPath = CommandLine.arguments[1]
let library = try! device.makeLibrary(URL: URL(fileURLWithPath: libPath))

let W = 64, H = 16

let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = library.makeFunction(name: "vertexShader")!
desc.fragmentFunction = library.makeFunction(name: "fragmentShader")!
desc.colorAttachments[0].pixelFormat = .bgra8Unorm
desc.colorAttachments[0].isBlendingEnabled = true
desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
let pipeline = try! device.makeRenderPipelineState(descriptor: desc)

let texDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
texDesc.usage = [.renderTarget, .shaderRead]
texDesc.storageMode = .managed
let texture = device.makeTexture(descriptor: texDesc)!

// Three points, spread across x, at heights -1, 0, +1 along the up axis.
let points: [PointVertex] = [
    PointVertex(position: [-0.5, 0, -1], color: [1, 0, 0, 1], intensity: 1,
                scanAngle: 0, returnNumber: 1, timeStamp: 0),
    PointVertex(position: [0, 0, 0], color: [1, 0, 0, 1], intensity: 1,
                scanAngle: 0, returnNumber: 1, timeStamp: 0),
    PointVertex(position: [0.5, 0, 1], color: [1, 0, 0, 1], intensity: 1,
                scanAngle: 0, returnNumber: 1, timeStamp: 0),
]

/// Maps (x, y, *) to clip (x, y, 0.5, 1), so all three land on screen at
/// distinct pixels regardless of their height.
let flatten = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                                      SIMD4<Float>(0, 1, 0, 0),
                                      SIMD4<Float>(0, 0, 0, 0),
                                      SIMD4<Float>(0, 0, 0.5, 1)))

/// Unused since DEPTH was removed; kept only so the matrices below read as a pair.
/// depths 0, 1 and 2.
let depthFromHeight = simd_float4x4(columns: (SIMD4<Float>(0, 0, 0, 0),
                                              SIMD4<Float>(0, 0, 0, 0),
                                              SIMD4<Float>(0, 0, -1, 0),
                                              SIMD4<Float>(0, 0, -1, 1)))

func baseUniforms() -> Uniforms {
    var u = Uniforms()
    u.modelViewProjection = flatten
    u.pointColor = [1, 0, 0, 1]
    u.heightAxis = [0, 0, 1]
    u.pointSize = 5
    u.minHeight = -1
    u.maxHeight = 1
    u.overlayStrength = 0
    u.sectionCentre = 0
    u.sectionHalf = 0
    u.visualizationMode = 0           // Solid
    u.useVertexColors = 0
    u.darkGround = 0
    return u
}

func render(_ uniforms: Uniforms) -> [UInt8] {
    var u = uniforms
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBytes(points, length: MemoryLayout<PointVertex>.stride * points.count,
                       index: Int(BufferIndexVertices.rawValue))
    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride,
                       index: Int(BufferIndexUniforms.rawValue))
    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride,
                         index: Int(BufferIndexUniforms.rawValue))
    enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: points.count)
    enc.endEncoding()

    let blit = cmd.makeBlitCommandEncoder()!
    blit.synchronize(resource: texture)
    blit.endEncoding()

    cmd.commit()
    cmd.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    texture.getBytes(&bytes, bytesPerRow: W * 4,
                     from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    return bytes
}

/// Peak red in the column band around an expected NDC x, as 0...1.
func redAt(_ pixels: [UInt8], ndcX: Float) -> Float {
    let centre = Int((ndcX * 0.5 + 0.5) * Float(W))
    var peak: UInt8 = 0
    for y in 0..<H {
        for x in max(0, centre - 4)..<min(W, centre + 4) {
            peak = max(peak, pixels[(y * W + x) * 4 + 2])   // BGRA -> red at +2
        }
    }
    return Float(peak) / 255
}

let xs: [Float] = [-0.5, 0, 0.5]
var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("  \(ok ? "pass" : "FAIL")  \(name.padding(toLength: 40, withPad: " ", startingAt: 0))\(detail)")
}

print("section")
do {
    let all = render(baseUniforms())
    let v = xs.map { redAt(all, ndcX: $0) }
    check("no section: all three points drawn", v.allSatisfy { $0 > 0.5 },
          "red = \(v.map { String(format: "%.2f", $0) }.joined(separator: ", "))")

    var u = baseUniforms()
    u.sectionCentre = 0
    u.sectionHalf = 0.5
    let band = render(u)
    let b = xs.map { redAt(band, ndcX: $0) }
    check("band ±0.5 keeps only the middle point",
          b[0] < 0.02 && b[1] > 0.5 && b[2] < 0.02,
          "red = \(b.map { String(format: "%.2f", $0) }.joined(separator: ", "))")

    // A culled point must vanish, not collapse onto the screen centre.
    var offset = baseUniforms()
    offset.sectionCentre = -1
    offset.sectionHalf = 0.25
    let low = render(offset)
    let l = xs.map { redAt(low, ndcX: $0) }
    check("band at the bottom keeps only the low point",
          l[0] > 0.5 && l[1] < 0.02 && l[2] < 0.02,
          "red = \(l.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
}

print("\ncombined")
do {
    // The overlay accumulates instead of painting a surface, and the cut must
    // still apply - the two operate at different stages of the pipeline.
    var u = baseUniforms()
    u.overlayStrength = 1
    u.sectionCentre = 0
    u.sectionHalf = 0.5
    let c = xs.map { redAt(render(u), ndcX: $0) }
    check("section cuts while the overlay accumulates",
          c[0] < 0.02 && c[2] < 0.02,
          "red = \(c.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
}

print(failures == 0 ? "\nall shader cases pass" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
