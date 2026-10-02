import Foundation
import simd

/// Parser for PLY (Polygon File Format) point clouds
enum PLYParser {

    enum Format {
        case ascii
        case binaryLittleEndian
        case binaryBigEndian
    }

    struct Property {
        let name: String
        let type: String
        let index: Int
    }

    static func parse(url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> PointCloud {
        ppLog("PLY: Loading \(url.lastPathComponent)")

        // Mapped: binary PLY can be very large, and the body is walked once.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // Find header end
        guard let headerEndRange = data.range(of: "end_header\n".data(using: .utf8)!) ??
                                   data.range(of: "end_header\r\n".data(using: .utf8)!) else {
            throw ParserError.invalidData
        }

        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ParserError.invalidData
        }

        // Parse header
        var format: Format = .ascii
        var vertexCount = 0
        var properties: [Property] = []

        let lines = headerString.components(separatedBy: .newlines)
        var propertyIndex = 0

        for line in lines {
            let parts = line.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { continue }

            switch parts[0] {
            case "format":
                if parts.count > 1 {
                    switch parts[1] {
                    case "ascii": format = .ascii
                    case "binary_little_endian": format = .binaryLittleEndian
                    case "binary_big_endian": format = .binaryBigEndian
                    default: break
                    }
                }

            case "element":
                if parts.count > 2 && parts[1] == "vertex" {
                    vertexCount = Int(parts[2]) ?? 0
                }

            case "property":
                if parts.count > 2 {
                    let type = parts[1]
                    let name = parts[2]
                    properties.append(Property(name: name, type: type, index: propertyIndex))
                    propertyIndex += 1
                }

            default:
                break
            }
        }

        guard vertexCount > 0 else {
            throw ParserError.invalidData
        }

        ppLog("PLY: \(vertexCount) vertices, format: \(format), properties: \(properties.count)")

        // Find property indices
        let xIdx = properties.first(where: { $0.name == "x" })?.index
        let yIdx = properties.first(where: { $0.name == "y" })?.index
        let zIdx = properties.first(where: { $0.name == "z" })?.index
        let rIdx = properties.first(where: { $0.name == "red" })?.index
        let gIdx = properties.first(where: { $0.name == "green" })?.index
        let bIdx = properties.first(where: { $0.name == "blue" })?.index
        let intensityIdx = properties.first(where: { $0.name == "intensity" || $0.name == "scalar_Intensity" })?.index

        guard let xi = xIdx, let yi = yIdx, let zi = zIdx else {
            throw ParserError.invalidData
        }

        let bodyData = data.subdata(in: headerEndRange.upperBound..<data.count)

        // Parse based on format
        switch format {
        case .ascii:
            return try parseASCII(bodyData,
                                  vertexCount: vertexCount,
                                  xIdx: xi, yIdx: yi, zIdx: zi,
                                  rIdx: rIdx, gIdx: gIdx, bIdx: bIdx,
                                  intensityIdx: intensityIdx,
                                  fileName: url.lastPathComponent,
                                  progress: progress)

        case .binaryLittleEndian:
            return try parseBinaryLE(bodyData,
                                     vertexCount: vertexCount,
                                     properties: properties,
                                     xIdx: xi, yIdx: yi, zIdx: zi,
                                     rIdx: rIdx, gIdx: gIdx, bIdx: bIdx,
                                     intensityIdx: intensityIdx,
                                     fileName: url.lastPathComponent,
                                     progress: progress)

        case .binaryBigEndian:
            throw ParserError.readError("Binary big-endian PLY not yet supported")
        }
    }

    private static func parseASCII(_ data: Data,
                                   vertexCount: Int,
                                   xIdx: Int, yIdx: Int, zIdx: Int,
                                   rIdx: Int?, gIdx: Int?, bIdx: Int?,
                                   intensityIdx: Int?,
                                   fileName: String,
                                   progress: (@Sendable (Double) -> Void)? = nil) throws -> PointCloud {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidData
        }

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>]? = (rIdx != nil && gIdx != nil && bIdx != nil) ? [] : nil
        var intensities: [Float]? = intensityIdx != nil ? [] : nil
        var origin: SIMD3<Double>? = nil

        positions.reserveCapacity(vertexCount)
        colors?.reserveCapacity(vertexCount)
        intensities?.reserveCapacity(vertexCount)

        let lines = string.components(separatedBy: .newlines)

        var lastPercent = -1
        for (rowIndex, line) in lines.prefix(vertexCount).enumerated() {
            if let progress = progress {
                let percent = rowIndex * 100 / max(vertexCount, 1)
                if percent != lastPercent { lastPercent = percent; progress(Double(percent) / 100) }
            }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count > max(xIdx, yIdx, zIdx) else { continue }

            guard let x = Double(parts[xIdx]),
                  let y = Double(parts[yIdx]),
                  let z = Double(parts[zIdx]) else {
                continue
            }

            // `Double("nan")` parses successfully; reject non-finite geometry
            // before it reaches the bounds calculation.
            guard x.isFinite, y.isFinite, z.isFinite else { continue }

            if origin == nil { origin = SIMD3<Double>(x, y, z) }
            let o = origin!
            positions.append(SIMD3<Float>(Float(x - o.x), Float(y - o.y), Float(z - o.z)))

            // Parse colors if available
            if let ri = rIdx, let gi = gIdx, let bi = bIdx,
               parts.count > max(ri, gi, bi) {
                let r = Float(parts[ri]) ?? 0
                let g = Float(parts[gi]) ?? 0
                let b = Float(parts[bi]) ?? 0
                // Normalize if values are in 0-255 range
                let scale: Float = max(r, g, b) > 1 ? 255.0 : 1.0
                colors?.append(SIMD4<Float>(r/scale, g/scale, b/scale, 1.0))
            }

            // Parse intensity if available
            if let ii = intensityIdx, parts.count > ii {
                let intensity = Float(parts[ii]) ?? 1.0
                intensities?.append(intensity > 1 ? intensity / 255.0 : intensity)
            }
        }

        ppLog("PLY: Parsed \(positions.count) ASCII points")

        return PointCloud(positions: positions,
                          colors: colors,
                          intensities: intensities,
                          origin: origin ?? .zero,
                          fileName: fileName)
    }

    private static func parseBinaryLE(_ data: Data,
                                      vertexCount: Int,
                                      properties: [Property],
                                      xIdx: Int, yIdx: Int, zIdx: Int,
                                      rIdx: Int?, gIdx: Int?, bIdx: Int?,
                                      intensityIdx: Int?,
                                      fileName: String,
                                      progress: (@Sendable (Double) -> Void)? = nil) throws -> PointCloud {
        // Calculate stride
        var stride = 0
        var offsets: [Int: Int] = [:]

        for prop in properties {
            offsets[prop.index] = stride
            stride += sizeOf(type: prop.type)
        }

        guard data.count >= stride * vertexCount else {
            throw ParserError.invalidData
        }

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>]? = (rIdx != nil && gIdx != nil && bIdx != nil) ? [] : nil
        var intensities: [Float]? = intensityIdx != nil ? [] : nil
        var origin: SIMD3<Double>? = nil

        positions.reserveCapacity(vertexCount)
        colors?.reserveCapacity(vertexCount)
        intensities?.reserveCapacity(vertexCount)

        let xType = properties.first(where: { $0.index == xIdx })?.type ?? "float"
        let rType = rIdx.flatMap { idx in properties.first(where: { $0.index == idx })?.type } ?? "uchar"

        var lastPercent = -1
        for i in 0..<vertexCount {
            if let progress = progress {
                let percent = i * 100 / max(vertexCount, 1)
                if percent != lastPercent { lastPercent = percent; progress(Double(percent) / 100) }
            }
            let baseOffset = i * stride

            // Read position
            let x = readPosition(data, at: baseOffset + offsets[xIdx]!, type: xType)
            let y = readPosition(data, at: baseOffset + offsets[yIdx]!, type: xType)
            let z = readPosition(data, at: baseOffset + offsets[zIdx]!, type: xType)

            // Skipping the whole record keeps the parallel colour/intensity
            // arrays aligned with `positions`.
            guard x.isFinite, y.isFinite, z.isFinite else { continue }

            if origin == nil { origin = SIMD3<Double>(x, y, z) }
            let o = origin!
            positions.append(SIMD3<Float>(Float(x - o.x), Float(y - o.y), Float(z - o.z)))

            // Read color
            if let ri = rIdx, let gi = gIdx, let bi = bIdx {
                let r = readValue(data, at: baseOffset + offsets[ri]!, type: rType)
                let g = readValue(data, at: baseOffset + offsets[gi]!, type: rType)
                let b = readValue(data, at: baseOffset + offsets[bi]!, type: rType)
                let scale: Float = rType == "uchar" ? 255.0 : 1.0
                colors?.append(SIMD4<Float>(r/scale, g/scale, b/scale, 1.0))
            }

            // Read intensity
            if let ii = intensityIdx {
                let iType = properties.first(where: { $0.index == ii })?.type ?? "float"
                var intensity = readValue(data, at: baseOffset + offsets[ii]!, type: iType)
                if intensity > 1 { intensity /= 255.0 }
                intensities?.append(intensity)
            }
        }

        ppLog("PLY: Parsed \(positions.count) binary points")

        return PointCloud(positions: positions,
                          colors: colors,
                          intensities: intensities,
                          origin: origin ?? .zero,
                          fileName: fileName)
    }

    private static func sizeOf(type: String) -> Int {
        switch type {
        case "char", "uchar", "int8", "uint8": return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "int", "uint", "int32", "uint32", "float": return 4
        case "double", "float64": return 8
        default: return 4
        }
    }

    /// Positional reader that keeps full precision.
    ///
    /// `readValue` narrows to Float immediately, which loses ~0.03m on
    /// georeferenced coordinates - and CloudCompare and similar tools write
    /// positions as `double` precisely because those coordinates are large.
    private static func readPosition(_ data: Data, at offset: Int, type: String) -> Double {
        guard offset >= 0, offset < data.count else { return 0 }
        switch type {
        case "double", "float64":
            guard offset + 8 <= data.count else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Double.self) }
        default:
            return Double(readValue(data, at: offset, type: type))
        }
    }

    private static func readValue(_ data: Data, at offset: Int, type: String) -> Float {
        guard offset >= 0 && offset < data.count else { return 0 }

        switch type {
        case "float":
            return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
        case "double":
            return Float(data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Double.self) })
        case "uchar", "uint8":
            return Float(data[offset])
        case "char", "int8":
            return Float(Int8(bitPattern: data[offset]))
        case "ushort", "uint16":
            return Float(data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) })
        case "int", "int32":
            return Float(data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) })
        case "uint", "uint32":
            return Float(data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) })
        default:
            return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Float.self) }
        }
    }
}
