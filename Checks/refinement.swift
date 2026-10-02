import Foundation
import MetalKit
import AppKit
import simd

// Progressive refinement draws a still frame in slices across several frames,
// into a texture that survives between them. The whole idea only holds if the
// sliced result is identical to the single-pass one - otherwise the picture
// changes as it sharpens, which is worse than the stall it replaces.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "pass" : "FAIL")  \(name.padding(toLength: 46, withPad: " ", startingAt: 0))\(detail)")
}

let device = MTLCreateSystemDefaultDevice()!
let W = 320, H = 240

let view = MTKView(frame: CGRect(x: 0, y: 0, width: W, height: H), device: device)
view.colorPixelFormat = .bgra8Unorm
view.depthStencilPixelFormat = .depth32Float

guard let renderer = Renderer(metalView: view) else {
    print("FAIL  renderer could not be created"); exit(1)
}

// A synthetic cloud, so the check needs no sample file on disk.
var vertices: [PointVertex] = []
var seed: UInt64 = 0x9E3779B97F4A7C15
func rand() -> Float {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Float(seed % 10_000) / 10_000 * 2 - 1
}
for _ in 0..<200_000 {
    vertices.append(PointVertex(position: [rand(), rand(), rand()],
                                color: [0.2, 0.2, 0.2, 1], intensity: 0.5,
                                scanAngle: 0, returnNumber: 1, timeStamp: 0))
}
let cloud = PointCloud(vertices: vertices, minBounds: [-1, -1, -1], maxBounds: [1, 1, 1],
                       hasColors: false, hasIntensity: true,
                       worldOrigin: .zero, fileName: "synthetic")
renderer.loadPointCloud(cloud)

let total = renderer.totalPointCount()
check("the cloud loaded", total > 0, "\(total) points")

let colourDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
colourDesc.usage = [.renderTarget, .shaderRead]
colourDesc.storageMode = .managed
let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
depthDesc.usage = .renderTarget
depthDesc.storageMode = .private

/// Render `total` points in `slices` passes into one texture, exactly as the
/// frame loop does, and read the result back.
func render(slices: Int) -> [UInt8] {
    let colour = device.makeTexture(descriptor: colourDesc)!
    let depth = device.makeTexture(descriptor: depthDesc)!
    let per = (total + slices - 1) / slices
    var drawn = 0

    for slice in 0..<slices {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = slice == 0 ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Renderer.backgroundClearColor(isDarkMode: false)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = slice == 0 ? .clear : .load
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0

        let cmd = renderer.commandQueue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        renderer.renderToEncoder(enc, viewSize: CGSize(width: W, height: H),
                                 from: drawn, count: min(per, total - drawn),
                                 includeGrid: slice == 0)
        enc.endEncoding()
        if slice == slices - 1 {
            let blit = cmd.makeBlitCommandEncoder()!
            blit.synchronize(resource: colour)
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        drawn += per
    }

    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    colour.getBytes(&bytes, bytesPerRow: W * 4,
                    from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    return bytes
}

func inked(_ pixels: [UInt8]) -> Int {
    let paper = Renderer.backgroundClearColor(isDarkMode: false)
    let pr = Int(paper.red * 255), pg = Int(paper.green * 255), pb = Int(paper.blue * 255)
    var n = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        if abs(Int(pixels[i + 2]) - pr) > 6 || abs(Int(pixels[i + 1]) - pg) > 6
            || abs(Int(pixels[i]) - pb) > 6 { n += 1 }
    }
    return n
}

// The empty case, first: with no cloud loaded nothing writes to the
// accumulation, so if the frame loop shows it before clearing it, the sheet
// comes up as uninitialised GPU memory. It did.
print("\nan empty sheet")
do {
    let colour = device.makeTexture(descriptor: colourDesc)!
    let depth = device.makeTexture(descriptor: depthDesc)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = colour
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = Renderer.backgroundClearColor(isDarkMode: false)
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .store

    let cmd = renderer.commandQueue.makeCommandBuffer()!
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    // No draw at all - the clear alone has to make the texture presentable.
    enc.endEncoding()
    let blit = cmd.makeBlitCommandEncoder()!
    blit.synchronize(resource: colour)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    colour.getBytes(&bytes, bytesPerRow: W * 4,
                    from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    check("a pass with no points still yields paper", inked(bytes) == 0,
          "\(inked(bytes)) non-paper pixels")
}

print("\nrefinement")
let once = render(slices: 1)
check("a single pass puts ink on the paper", inked(once) > 0,
      "\(inked(once)) of \(W * H) pixels")

for slices in [2, 5, 17] {
    let sliced = render(slices: slices)
    var differing = 0
    for i in stride(from: 0, to: once.count, by: 4) where
        abs(Int(sliced[i]) - Int(once[i])) > 1
        || abs(Int(sliced[i + 1]) - Int(once[i + 1])) > 1
        || abs(Int(sliced[i + 2]) - Int(once[i + 2])) > 1 {
        differing += 1
    }
    check("\(slices) slices match one pass", differing == 0, "\(differing) pixels differ")
}

print(failures == 0 ? "\nrefinement is faithful" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
