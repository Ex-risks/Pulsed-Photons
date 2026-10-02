import Foundation
import simd

/// Parser for XYZ/TXT point cloud files
enum XYZParser {

    static func parse(url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> PointCloud {
        ppLog("XYZ: Loading \(url.lastPathComponent)")

        let string = try String(contentsOf: url, encoding: .utf8)
        let lines = string.components(separatedBy: .newlines)

        guard !lines.isEmpty else {
            throw ParserError.invalidData
        }

        // Detect delimiter from first non-empty line
        var delimiter: Character = " "
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("//") {
                delimiter = detectDelimiter(in: trimmed)
                break
            }
        }

        ppLog("XYZ: Detected delimiter: '\(delimiter == " " ? "space" : String(delimiter))'")

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>]? = nil
        var intensities: [Float]? = nil
        var skipped = 0
        var origin: SIMD3<Double>? = nil

        // Estimate capacity
        positions.reserveCapacity(lines.count)

        var lastPercent = -1
        for (lineIndex, line) in lines.enumerated() {
            if let progress = progress {
                let percent = lineIndex * 100 / max(lines.count, 1)
                if percent != lastPercent { lastPercent = percent; progress(Double(percent) / 100) }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }

            let parts = trimmed.split(separator: delimiter).map { String($0).trimmingCharacters(in: .whitespaces) }

            // Parse as Double. Survey XYZ is routinely in UTM, where narrowing
            // straight to Float resolves only ~0.03m - coarser than the
            // instrument that produced it.
            guard parts.count >= 3,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  let z = Double(parts[2]) else {
                continue
            }

            // `Double("nan")` and `Double("inf")` parse successfully, so reject
            // non-finite geometry here rather than letting it poison bounds.
            guard x.isFinite, y.isFinite, z.isFinite else {
                skipped += 1
                continue
            }

            // Anchor on the first point so stored offsets stay small; Float
            // then gives sub-millimetre precision over a multi-kilometre span.
            if origin == nil { origin = SIMD3<Double>(x, y, z) }
            let o = origin!
            positions.append(SIMD3<Float>(Float(x - o.x), Float(y - o.y), Float(z - o.z)))

            // Check for additional data (RGB or intensity)
            if parts.count >= 6 {
                // Likely has RGB
                if colors == nil {
                    colors = []
                    colors?.reserveCapacity(lines.count)
                }

                let r = Float(parts[3]) ?? 0
                let g = Float(parts[4]) ?? 0
                let b = Float(parts[5]) ?? 0

                // Normalize if in 0-255 range
                let scale: Float = max(r, g, b) > 1 ? 255.0 : 1.0
                colors?.append(SIMD4<Float>(r/scale, g/scale, b/scale, 1.0))

                // Check for intensity as 7th column
                if parts.count >= 7 {
                    if intensities == nil {
                        intensities = []
                        intensities?.reserveCapacity(lines.count)
                    }
                    var intensity = Float(parts[6]) ?? 1.0
                    if intensity > 1 { intensity /= 255.0 }
                    intensities?.append(intensity)
                }
            } else if parts.count >= 4 {
                // Single extra column - likely intensity
                if intensities == nil {
                    intensities = []
                    intensities?.reserveCapacity(lines.count)
                }
                var intensity = Float(parts[3]) ?? 1.0
                if intensity > 1 && intensity <= 255 { intensity /= 255.0 }
                intensities?.append(intensity)
            }
        }

        guard !positions.isEmpty else {
            throw ParserError.invalidData
        }

        ppLog("XYZ: parsed \(positions.count) points" + (skipped > 0 ? ", skipped \(skipped) non-finite" : ""))

        return PointCloud(positions: positions,
                          colors: colors,
                          intensities: intensities,
                          origin: origin ?? .zero,
                          fileName: url.lastPathComponent)
    }

    private static func detectDelimiter(in line: String) -> Character {
        if line.contains(",") {
            return ","
        } else if line.contains("\t") {
            return "\t"
        } else if line.contains(";") {
            return ";"
        }
        return " "
    }
}
