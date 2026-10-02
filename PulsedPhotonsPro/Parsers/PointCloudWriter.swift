import Foundation
import simd

/// Formats a loaded cloud can be written back out as.
///
/// The set is deliberately small and each earns its place: PLY because it is
/// what every mesh and photogrammetry tool reads, XYZ because anything at all
/// will read it, and LAS because it is what this application is mostly given
/// and a viewer that cannot hand back its own input format is a dead end.
enum PointCloudFormat: String, CaseIterable, Identifiable {
    case ply, xyz, las

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var name: String { rawValue.uppercased() }

    /// What the format actually preserves, stated plainly - the difference
    /// between them is entirely what survives the trip.
    var summary: String {
        switch self {
        case .ply: return "binary · position and colour"
        case .xyz: return "text · position and colour"
        case .las: return "binary · position, colour, intensity, georeference"
        }
    }
}

/// Writes a cloud to disk.
///
/// Streamed in blocks rather than built in memory: a 50M-point PLY is 750MB and
/// an XYZ of the same cloud is larger still, and neither should ever have to be
/// resident in full alongside the cloud it came from.
enum PointCloudWriter {

    /// Vertices per block. Large enough that syscall overhead disappears, small
    /// enough that the staging buffer stays a few megabytes.
    private static let blockSize = 262_144

    static func write(_ cloud: PointCloud,
                      to url: URL,
                      format: PointCloudFormat,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ParserError.readError("Could not open \(url.lastPathComponent) for writing")
        }
        defer { try? handle.close() }

        switch format {
        case .ply: try writePLY(cloud, to: handle, progress: progress)
        case .xyz: try writeXYZ(cloud, to: handle, progress: progress)
        case .las: try writeLAS(cloud, to: handle, progress: progress)
        }
    }

    // MARK: - PLY

    /// Binary little-endian PLY. Position as double, colour as three bytes.
    ///
    /// Double, not float, and the reason is measurable: written in world
    /// coordinates a georeferenced easting runs to seven digits, where a
    /// float's spacing is about half a metre. Round-tripping this cloud as
    /// float moved points by up to 249mm - the very precision loss the app
    /// avoids internally by anchoring positions to an origin. Eight bytes a
    /// component is the price of handing back what was read in.
    private static func writePLY(_ cloud: PointCloud, to handle: FileHandle,
                                 progress: (@Sendable (Double) -> Void)?) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment written by Pulsed Photons
        element vertex \(cloud.pointCount)
        property double x
        property double y
        property double z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        handle.write(Data(header.utf8))

        // Positions go out in world coordinates, so a cloud written here and
        // read back lands where it started rather than at the origin.
        let o = cloud.worldOrigin
        stream(cloud.pointCount, progress: progress) { range in
            var block = Data()
            block.reserveCapacity(range.count * 27)
            for i in range {
                let v = cloud.vertices[i]
                for c in [Double(v.position.x) + o.x,
                          Double(v.position.y) + o.y,
                          Double(v.position.z) + o.z] {
                    withUnsafeBytes(of: c.bitPattern.littleEndian) { block.append(contentsOf: $0) }
                }
                block.append(byte(v.color.x))
                block.append(byte(v.color.y))
                block.append(byte(v.color.z))
            }
            handle.write(block)
        }
    }

    // MARK: - XYZ

    /// Space-separated text. Three decimals is a millimetre, which is finer
    /// than any scanner this reads and keeps the file from doubling in size for
    /// digits that mean nothing.
    private static func writeXYZ(_ cloud: PointCloud, to handle: FileHandle,
                                 progress: (@Sendable (Double) -> Void)?) throws {
        let o = cloud.worldOrigin
        let colour = cloud.hasColors

        stream(cloud.pointCount, progress: progress) { range in
            var text = ""
            text.reserveCapacity(range.count * 48)
            for i in range {
                let v = cloud.vertices[i]
                text += String(format: "%.3f %.3f %.3f",
                               Double(v.position.x) + o.x,
                               Double(v.position.y) + o.y,
                               Double(v.position.z) + o.z)
                if colour {
                    text += String(format: " %d %d %d",
                                   Int(byte(v.color.x)), Int(byte(v.color.y)), Int(byte(v.color.z)))
                }
                text += "\n"
            }
            handle.write(Data(text.utf8))
        }
    }

    // MARK: - LAS

    /// LAS 1.2, point data record format 2 - position, intensity and RGB.
    ///
    /// Format 2 rather than 0 so colour survives even when the source had none;
    /// a grey cloud is a smaller lie than a colourless file that claims to be
    /// the same data.
    private static func writeLAS(_ cloud: PointCloud, to handle: FileHandle,
                                 progress: (@Sendable (Double) -> Void)?) throws {
        let recordLength = 26
        let headerSize = 227
        let scale = 0.001                     // millimetres
        let o = cloud.worldOrigin

        // The offset is the cloud's own origin, so the stored integers stay
        // small and centred rather than running off the end of Int32.
        var header = [UInt8](repeating: 0, count: headerSize)
        for (i, b) in Array("LASF".utf8).enumerated() { header[i] = b }
        header[24] = 1                        // version major
        header[25] = 2                        // version minor
        write16(&header, 94, UInt16(headerSize))
        write32(&header, 96, UInt32(headerSize))
        write32(&header, 100, 0)              // no VLRs
        header[104] = 2                       // point data record format
        write16(&header, 105, UInt16(recordLength))
        write32(&header, 107, UInt32(min(cloud.pointCount, Int(UInt32.max))))

        writeDouble(&header, 131, scale)
        writeDouble(&header, 139, scale)
        writeDouble(&header, 147, scale)
        writeDouble(&header, 155, o.x)
        writeDouble(&header, 163, o.y)
        writeDouble(&header, 171, o.z)

        // Bounds, in world coordinates, in the order the spec gives them:
        // maxX minX maxY minY maxZ minZ.
        let lo = cloud.minBounds, hi = cloud.maxBounds
        writeDouble(&header, 179, Double(hi.x) + o.x)
        writeDouble(&header, 187, Double(lo.x) + o.x)
        writeDouble(&header, 195, Double(hi.y) + o.y)
        writeDouble(&header, 203, Double(lo.y) + o.y)
        writeDouble(&header, 211, Double(hi.z) + o.z)
        writeDouble(&header, 219, Double(lo.z) + o.z)

        handle.write(Data(header))

        stream(cloud.pointCount, progress: progress) { range in
            var block = Data()
            block.reserveCapacity(range.count * recordLength)
            for i in range {
                let v = cloud.vertices[i]
                // Positions are already relative to the origin written above,
                // so no re-basing is needed here - just the scale.
                for component in [v.position.x, v.position.y, v.position.z] {
                    let raw = Int32(clampingRounded: Double(component) / scale)
                    withUnsafeBytes(of: raw.littleEndian) { block.append(contentsOf: $0) }
                }
                let intensity = UInt16(max(0, min(1, v.intensity)) * 65535)
                withUnsafeBytes(of: intensity.littleEndian) { block.append(contentsOf: $0) }

                block.append(UInt8(max(1, min(7, Int(v.returnNumber)))))   // return flags
                block.append(0)                                            // classification
                block.append(UInt8(bitPattern: Int8(max(-128, min(127, Int(v.scanAngle))))))
                block.append(0)                                            // user data
                block.append(contentsOf: [0, 0])                           // point source ID

                for channel in [v.color.x, v.color.y, v.color.z] {
                    let c = UInt16(max(0, min(1, channel)) * 65535)
                    withUnsafeBytes(of: c.littleEndian) { block.append(contentsOf: $0) }
                }
            }
            handle.write(block)
        }
    }

    // MARK: - Helpers

    /// Walk the cloud in blocks, reporting progress once per block.
    private static func stream(_ count: Int,
                               progress: (@Sendable (Double) -> Void)?,
                               body: (Range<Int>) -> Void) {
        var start = 0
        while start < count {
            let end = min(start + blockSize, count)
            body(start..<end)
            start = end
            progress?(Double(start) / Double(max(count, 1)))
        }
    }

    private static func byte(_ channel: Float) -> UInt8 {
        UInt8(max(0, min(1, channel)) * 255)
    }

    private static func write16(_ b: inout [UInt8], _ at: Int, _ v: UInt16) {
        b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8(v >> 8)
    }

    private static func write32(_ b: inout [UInt8], _ at: Int, _ v: UInt32) {
        for i in 0..<4 { b[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }

    private static func writeDouble(_ b: inout [UInt8], _ at: Int, _ v: Double) {
        let bits = v.bitPattern.littleEndian
        withUnsafeBytes(of: bits) { raw in
            for i in 0..<8 { b[at + i] = raw[i] }
        }
    }
}

private extension Int32 {
    /// Saturating conversion. A coordinate past ±2147km is corrupt rather than
    /// distant, and trapping on it would take the application down mid-write.
    init(clampingRounded value: Double) {
        guard value.isFinite else { self = 0; return }
        let lo = Double(Int32.min), hi = Double(Int32.max)
        self = Int32(Swift.max(lo, Swift.min(hi, value.rounded())))
    }
}
