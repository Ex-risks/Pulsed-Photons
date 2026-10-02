import Foundation
import simd

// Stubs for the two symbols the parsers reach for outside their own folder.
func ppLog(_ message: @autoclosure () -> String) { }

enum ParserError: LocalizedError {
    case invalidData
    case readError(String)
    case unsupportedFormat(String)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "invalid"
        case .readError(let m): return m
        case .unsupportedFormat(let f): return "unsupported: \(f)"
        }
    }
}

// Every format the app writes is read back with the app's own parser and
// compared against what went in. A writer that produces a plausible but
// malformed header fails here rather than three tools downstream.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "pass" : "FAIL")  \(name.padding(toLength: 44, withPad: " ", startingAt: 0))\(detail)")
}

// A cloud with a georeferenced origin, so the round trip has to preserve the
// world position and not just the local offsets.
let origin = SIMD3<Double>(456789.123, 5432198.765, 137.5)
var vertices: [PointVertex] = []
var seed: UInt64 = 0x2545F4914F6CDD1D
func rand() -> Float {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    return Float(seed % 20_000) / 10_000 - 1
}
for i in 0..<5_000 {
    vertices.append(PointVertex(position: [rand() * 40, rand() * 40, rand() * 8],
                                color: [Float(i % 255) / 255, 0.5, 0.25, 1],
                                intensity: Float(i % 100) / 100,
                                scanAngle: 0, returnNumber: 1, timeStamp: 0))
}
var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
for v in vertices { lo = simd_min(lo, v.position); hi = simd_max(hi, v.position) }

let source = PointCloud(vertices: vertices, minBounds: lo, maxBounds: hi,
                        hasColors: true, hasIntensity: true,
                        worldOrigin: origin, fileName: "source")

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pp-writers-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

/// Largest world-space discrepancy between two clouds, point for point.
func worstDrift(_ a: PointCloud, _ b: PointCloud) -> Double {
    var worst = 0.0
    for i in 0..<min(a.pointCount, b.pointCount) {
        let pa = SIMD3<Double>(Double(a.vertices[i].position.x),
                               Double(a.vertices[i].position.y),
                               Double(a.vertices[i].position.z)) + a.worldOrigin
        let pb = SIMD3<Double>(Double(b.vertices[i].position.x),
                               Double(b.vertices[i].position.y),
                               Double(b.vertices[i].position.z)) + b.worldOrigin
        worst = max(worst, simd_reduce_max(abs(pa - pb)))
    }
    return worst
}

for format in PointCloudFormat.allCases {
    print("\n\(format.name)")
    let url = dir.appendingPathComponent("out.\(format.fileExtension)")

    do {
        try PointCloudWriter.write(source, to: url, format: format)
    } catch {
        check("writes", false, "\(error)")
        continue
    }

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    check("writes a non-empty file", (size ?? 0) > 0, "\((size ?? 0) / 1024)KB")

    let readBack: PointCloud
    do {
        switch format {
        case .ply: readBack = try await PLYParser.parse(url: url)
        case .xyz: readBack = try await XYZParser.parse(url: url)
        case .las: readBack = try await LASParser.parse(url: url)
        }
    } catch {
        check("reads back", false, "\(error)")
        continue
    }

    check("every point survives", readBack.pointCount == source.pointCount,
          "\(readBack.pointCount) of \(source.pointCount)")

    // A millimetre is the quantisation LAS is written at and the precision XYZ
    // is written to, so nothing should drift further than that.
    let drift = worstDrift(source, readBack)
    check("positions land within a millimetre", drift < 0.0015,
          String(format: "worst %.5fm", drift))

    check("colour survives", readBack.hasColors, readBack.hasColors ? "" : "lost")

    if format == .las {
        check("intensity survives", readBack.hasIntensity)
    }
}

print(failures == 0 ? "\nevery format round trips" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
