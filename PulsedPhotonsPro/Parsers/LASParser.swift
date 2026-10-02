import Foundation
import simd

/// Parser for LAS (LiDAR) point cloud files
/// Supports LAS 1.2-1.4, Point Data Record Formats 0-10
///
/// Single pass, straight into the interleaved vertex array, over a
/// memory-mapped file. The previous version read the whole file into RAM and
/// staged six parallel attribute arrays before interleaving, which cost roughly
/// 104 bytes per point at peak plus the file itself; this costs 48, and the
/// file is paged by the OS rather than resident.
enum LASParser {

    static func parse(url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> PointCloud {
        let data: Data
        do {
            // Mapped, not read: a 100M-point LAS is ~3.4GB and does not need
            // to be resident to be walked once, sequentially.
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ParserError.readError("Could not read file: \(error.localizedDescription)")
        }

        guard data.count >= 227 else { throw ParserError.invalidData }

        guard String(data: data.subdata(in: 0..<4), encoding: .ascii) == "LASF" else {
            throw ParserError.invalidData
        }

        let versionMajor = data[24]
        let versionMinor = data[25]
        guard versionMajor == 1 && versionMinor <= 4 else {
            throw ParserError.readError("Unsupported LAS version \(versionMajor).\(versionMinor)")
        }

        let pointDataOffset = readUInt32(data, at: 96)
        let pointFormat = data[104]
        let pointRecordLength = readUInt16(data, at: 105)

        let numberOfPoints: UInt64
        if versionMinor >= 4 && data.count >= 255 {
            let extended = readUInt64(data, at: 247)
            // 1.4 files may still carry the count only in the legacy field.
            numberOfPoints = extended > 0 ? extended : UInt64(readUInt32(data, at: 107))
        } else {
            numberOfPoints = UInt64(readUInt32(data, at: 107))
        }

        let xScale = readDouble(data, at: 131)
        let yScale = readDouble(data, at: 139)
        let zScale = readDouble(data, at: 147)
        let xOffset = readDouble(data, at: 155)
        let yOffset = readDouble(data, at: 163)
        let zOffset = readDouble(data, at: 171)

        // The coordinate system, for units. The geometry above is already true
        // to scale - scale factor and offset see to that - so this only
        // supplies the name of the unit those numbers are counted in.
        let headerSize = Int(readUInt16(data, at: 94))
        let vlrCount = Int(readUInt32(data, at: 100))
        let usesWKT = (readUInt16(data, at: 6) & 0x0010) != 0
        let declaredUnit = linearUnit(in: data,
                                      headerSize: headerSize,
                                      vlrCount: vlrCount,
                                      preferWKT: usesWKT)

        ppLog("LAS: \(numberOfPoints) points, format \(pointFormat), record \(pointRecordLength) bytes, "
              + "unit \(declaredUnit?.kind.name ?? "undeclared")")

        let hasRGB = [2, 3, 5, 7, 8, 10].contains(Int(pointFormat))

        let pointCount = Int(numberOfPoints)
        let pointDataStart = Int(pointDataOffset)
        let recordLength = Int(pointRecordLength)

        guard pointCount > 0, recordLength > 0 else { throw ParserError.invalidData }

        let requiredSize = pointDataStart + pointCount * recordLength
        guard data.count >= requiredSize else {
            throw ParserError.readError("File truncated: expected \(requiredSize) bytes, got \(data.count)")
        }

        // RGB byte offset within a record, by point data record format.
        let rgbOffset: Int
        switch pointFormat {
        case 2: rgbOffset = 20
        case 3, 5: rgbOffset = 28
        case 7, 8, 10: rgbOffset = 30
        default: rgbOffset = 20
        }
        let legacyFormat = pointFormat <= 5

        return try await Task.detached(priority: .userInitiated) {
            var vertices = [PointVertex]()
            vertices.reserveCapacity(pointCount)

            var lo = SIMD3<Float>(repeating: .infinity)
            var hi = SIMD3<Float>(repeating: -.infinity)
            var origin: SIMD3<Double>? = nil
            var lastPercent = -1

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<pointCount {
                    let o = pointDataStart + i * recordLength

                    let xRaw = raw.loadUnaligned(fromByteOffset: o, as: Int32.self)
                    let yRaw = raw.loadUnaligned(fromByteOffset: o + 4, as: Int32.self)
                    let zRaw = raw.loadUnaligned(fromByteOffset: o + 8, as: Int32.self)

                    let x = Double(xRaw) * xScale + xOffset
                    let y = Double(yRaw) * yScale + yOffset
                    let z = Double(zRaw) * zScale + zOffset

                    // A corrupt scale/offset in the header yields non-finite
                    // coordinates; skipping the record keeps bounds clean.
                    guard x.isFinite, y.isFinite, z.isFinite else { continue }

                    // Anchor on the first kept point so stored offsets stay
                    // small and Float keeps sub-millimetre precision over a
                    // multi-kilometre span.
                    if origin == nil { origin = SIMD3<Double>(x, y, z) }
                    let ori = origin!
                    let position = SIMD3<Float>(Float(x - ori.x), Float(y - ori.y), Float(z - ori.z))

                    let intensity = Float(raw.loadUnaligned(fromByteOffset: o + 12, as: UInt16.self)) / 65535.0

                    let returnByte = raw.loadUnaligned(fromByteOffset: o + 14, as: UInt8.self)
                    let returnNumber: Float
                    let scanAngle: Float
                    if legacyFormat {
                        returnNumber = Float(returnByte & 0x07)
                        scanAngle = Float(Int8(bitPattern: raw.loadUnaligned(fromByteOffset: o + 16, as: UInt8.self)))
                    } else {
                        returnNumber = Float(returnByte & 0x0F)
                        scanAngle = Float(raw.loadUnaligned(fromByteOffset: o + 18, as: Int16.self)) * 0.006
                    }

                    var color = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
                    if hasRGB {
                        let c = o + rgbOffset
                        color = SIMD4<Float>(
                            Float(raw.loadUnaligned(fromByteOffset: c, as: UInt16.self)) / 65535.0,
                            Float(raw.loadUnaligned(fromByteOffset: c + 2, as: UInt16.self)) / 65535.0,
                            Float(raw.loadUnaligned(fromByteOffset: c + 4, as: UInt16.self)) / 65535.0,
                            1.0)
                    }

                    vertices.append(PointVertex(
                        position: position,
                        color: color,
                        intensity: intensity,
                        scanAngle: scanAngle,
                        returnNumber: returnNumber,
                        // Acquisition order, not GPS time. Normalising real GPS
                        // time needs its min and max, i.e. a second pass or an
                        // 8-byte-per-point staging array; nothing reads this
                        // field today, so neither is worth paying for.
                        timeStamp: Float(i) / Float(max(pointCount - 1, 1))
                    ))

                    lo = min(lo, position)
                    hi = max(hi, position)

                    if let progress = progress {
                        let percent = i * 100 / pointCount
                        if percent != lastPercent {
                            lastPercent = percent
                            progress(Double(percent) / 100)
                        }
                    }
                }
            }

            guard !vertices.isEmpty else { throw ParserError.invalidData }

            // Recentre on the bounding-box centre. Small-magnitude arithmetic
            // over resident memory, so this second walk is cheap.
            let shift = (lo + hi) * 0.5
            for j in 0..<vertices.count {
                vertices[j].position -= shift
            }

            let worldOrigin = (origin ?? .zero)
                + SIMD3<Double>(Double(shift.x), Double(shift.y), Double(shift.z))

            ppLog("LAS: parsed \(vertices.count) points, origin \(worldOrigin)")

            var cloud = PointCloud(vertices: vertices,
                                   minBounds: lo - shift,
                                   maxBounds: hi - shift,
                                   hasColors: hasRGB,
                                   hasIntensity: true,
                                   worldOrigin: worldOrigin,
                                   fileName: url.lastPathComponent)
            if let declaredUnit { cloud.units = declaredUnit }
            return cloud
        }.value
    }

    // MARK: - Coordinate system

    /// Linear unit declared by the file's coordinate system, if it declares one.
    ///
    /// Two encodings, by version. Through 1.3 the CRS is a set of GeoTIFF keys
    /// in VLR 34735; 1.4 may instead carry OGC WKT in VLR 2112, flagged by bit
    /// 4 of the global encoding. Both sit under the `LASF_Projection` user ID,
    /// and a 1.4 file can carry both, so the flag decides which one wins.
    ///
    /// Returns nil rather than guessing: an undeclared unit is a fact worth
    /// showing, not a gap to paper over.
    /// Internal rather than private so it can be exercised directly against a
    /// file header, without paying for a full parse of its points.
    static func linearUnit(in data: Data,
                           headerSize: Int,
                           vlrCount: Int,
                           preferWKT: Bool) -> LinearUnit? {
        guard headerSize >= 227, vlrCount > 0 else { return nil }

        var geoKeys: Range<Int>?
        var wkt: Range<Int>?

        // Each VLR is a 54-byte header followed by its payload. Walking them
        // is the only way to find one - there is no index.
        var offset = headerSize
        for _ in 0..<vlrCount {
            guard offset + 54 <= data.count else { break }
            let recordID = readUInt16(data, at: offset + 18)
            let length = Int(readUInt16(data, at: offset + 20))
            let body = offset + 54
            guard body + length <= data.count else { break }

            switch recordID {
            case 34735: geoKeys = body..<(body + length)
            case 2112:  wkt = body..<(body + length)
            default:    break
            }
            offset = body + length
        }

        if preferWKT, let wkt, let unit = linearUnitFromWKT(data, in: wkt) { return unit }
        if let geoKeys, let unit = linearUnitFromGeoKeys(data, in: geoKeys) { return unit }
        if let wkt, let unit = linearUnitFromWKT(data, in: wkt) { return unit }
        return nil
    }

    /// GeoTIFF key directory: a four-`UInt16` header, then one 8-byte entry per
    /// key. `ProjLinearUnitsGeoKey` (3076) carries its value inline when the
    /// tag location is 0; when it points at another tag the unit is a custom
    /// one this cannot name, so it is treated as undeclared.
    private static func linearUnitFromGeoKeys(_ data: Data, in range: Range<Int>) -> LinearUnit? {
        guard range.count >= 8 else { return nil }
        let keyCount = Int(readUInt16(data, at: range.lowerBound + 6))

        for k in 0..<keyCount {
            let entry = range.lowerBound + 8 + k * 8
            guard entry + 8 <= range.upperBound else { break }
            guard readUInt16(data, at: entry) == 3076,
                  readUInt16(data, at: entry + 2) == 0 else { continue }

            switch readUInt16(data, at: entry + 6) {
            case 9001: return LinearUnit(kind: .metre, isDeclared: true)
            case 9002: return LinearUnit(kind: .foot, isDeclared: true)
            case 9003: return LinearUnit(kind: .usSurveyFoot, isDeclared: true)
            default:   return nil
            }
        }
        return nil
    }

    /// OGC WKT, matched on the unit names it uses.
    ///
    /// Feet are tested before metres, and that order is load-bearing: a
    /// foot-based projected CRS still defines its ellipsoid in metres, so
    /// `LENGTHUNIT["metre",1]` appears in the text either way. Only a
    /// foot-based CRS mentions feet, so the presence of feet is the signal.
    private static func linearUnitFromWKT(_ data: Data, in range: Range<Int>) -> LinearUnit? {
        let bytes = data.subdata(in: range)
        guard let text = String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: .isoLatin1) else { return nil }
        let lower = text.lowercased()

        if lower.contains("us survey foot") || lower.contains("us_survey_foot") {
            return LinearUnit(kind: .usSurveyFoot, isDeclared: true)
        }
        if lower.contains("foot") || lower.contains("feet") {
            return LinearUnit(kind: .foot, isDeclared: true)
        }
        if lower.contains("metre") || lower.contains("meter") {
            return LinearUnit(kind: .metre, isDeclared: true)
        }
        return nil
    }

    // MARK: - Header readers
    //
    // Only used on the 227-byte header, so Data subscripting is fine here; the
    // per-point path uses an unsafe raw pointer instead.

    private static func readDouble(_ data: Data, at offset: Int) -> Double {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Double.self) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(data[offset + b]) << (8 * UInt64(b)) }
        return v
    }
}
