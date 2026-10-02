import Foundation
import simd

/// The linear unit a cloud's coordinates are expressed in.
///
/// LAS coordinates arrive already multiplied by the header's scale factor and
/// shifted by its offset, so the geometry is dimensionally true the moment it
/// is parsed. What a file may or may not say is what the number *means*.
///
/// `isDeclared` keeps those two cases apart, and the interface shows them
/// differently. A distance that will end up in a report should state whether
/// the app read its unit from the coordinate system or assumed one.
struct LinearUnit: Equatable, Sendable {

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case metre, foot, usSurveyFoot

        var id: String { rawValue }

        /// Length of one unit in metres. The US survey foot differs from the
        /// international foot by two parts per million - negligible over a
        /// room, but a 12mm error across a 6km site.
        var inMetres: Double {
            switch self {
            case .metre: return 1
            case .foot: return 0.3048
            case .usSurveyFoot: return 1200.0 / 3937.0
            }
        }

        var abbreviation: String {
            switch self {
            case .metre: return "m"
            case .foot, .usSurveyFoot: return "ft"
            }
        }

        var name: String {
            switch self {
            case .metre: return "metres"
            case .foot: return "feet"
            case .usSurveyFoot: return "us feet"
            }
        }
    }

    var kind: Kind

    /// True when someone stated this unit - either the file's coordinate
    /// system or the user. False means nobody has, and the app is guessing.
    ///
    /// The interface shows the two cases differently, because in practice most
    /// LAS in the wild carries no coordinate system at all, and a measurement
    /// bound for a report should not quietly imply a unit it was never told.
    var isDeclared: Bool

    /// The safe assumption, and marked as one. Metric is what the large
    /// majority of lidar is delivered in, but PLY and XYZ carry no coordinate
    /// system at all, so for those it can only ever be a guess.
    static let assumedMetre = LinearUnit(kind: .metre, isDeclared: false)
}

/// Point cloud data container
struct PointCloud {
    /// Raw vertex data for Metal rendering
    let vertices: [PointVertex]

    /// Number of points
    var pointCount: Int { vertices.count }

    /// Bounding box minimum
    let minBounds: SIMD3<Float>

    /// Bounding box maximum
    let maxBounds: SIMD3<Float>

    /// Whether the point cloud has RGB color data
    let hasColors: Bool

    /// Whether the point cloud has intensity data
    let hasIntensity: Bool

    /// File name
    let fileName: String

    /// Linear unit of the coordinates, as declared by the file's coordinate
    /// system. Formats that carry no CRS (PLY, XYZ) leave this at the assumed
    /// default; the user can override it, which is held in the view model
    /// rather than here, because this records what the *file* said.
    var units: LinearUnit = .assumedMetre

    /// World-space position of this cloud's local origin.
    ///
    /// Positions are stored relative to it so they stay small enough for
    /// `Float` to be precise. Georeferenced data routinely has UTM coordinates
    /// like 456789.123, where `Float` resolves only to ~0.03m - worse than the
    /// scanner. Add this back to recover true world coordinates.
    let worldOrigin: SIMD3<Double>

    /// Center of the bounding box
    var center: SIMD3<Float> {
        (minBounds + maxBounds) * 0.5
    }

    /// Size of the bounding box
    var size: SIMD3<Float> {
        maxBounds - minBounds
    }

    /// Adopt an already-interleaved vertex array.
    ///
    /// Lets a parser build vertices directly instead of staging parallel
    /// attribute arrays and interleaving afterwards - the difference between
    /// ~104 and 48 bytes per point at peak.
    init(vertices: [PointVertex],
         minBounds: SIMD3<Float>,
         maxBounds: SIMD3<Float>,
         hasColors: Bool,
         hasIntensity: Bool,
         worldOrigin: SIMD3<Double>,
         fileName: String) {
        self.vertices = vertices
        self.minBounds = minBounds
        self.maxBounds = maxBounds
        self.hasColors = hasColors
        self.hasIntensity = hasIntensity
        self.worldOrigin = worldOrigin
        self.fileName = fileName
    }

    /// Initialize from raw point data.
    ///
    /// `positions` are expected relative to `origin` - parsers subtract a
    /// provisional origin in `Double` before narrowing, so precision survives
    /// georeferenced coordinates. This then recentres on the bounding-box
    /// centre, which is cheap and exact because the values are already small,
    /// and folds that shift into `worldOrigin`.
    init(positions: [SIMD3<Float>],
         colors: [SIMD4<Float>]? = nil,
         intensities: [Float]? = nil,
         scanAngles: [Float]? = nil,
         returnNumbers: [Float]? = nil,
         timeStamps: [Float]? = nil,
         origin: SIMD3<Double> = .zero,
         fileName: String = "Untitled") {

        var minB = SIMD3<Float>(repeating: .infinity)
        var maxB = SIMD3<Float>(repeating: -.infinity)
        for p in positions {
            minB = min(minB, p)
            maxB = max(maxB, p)
        }
        let shift = positions.isEmpty ? .zero : (minB + maxB) * 0.5

        // One bounds check per attribute array, rather than one per point per
        // attribute via the `[safe:]` subscript.
        let n = positions.count
        let hasColor = (colors?.count ?? 0) == n
        let hasInt = (intensities?.count ?? 0) == n
        let hasAngle = (scanAngles?.count ?? 0) == n
        let hasReturn = (returnNumbers?.count ?? 0) == n
        let hasTime = (timeStamps?.count ?? 0) == n

        var vertices: [PointVertex] = []
        vertices.reserveCapacity(n)

        for i in 0..<n {
            vertices.append(PointVertex(
                position: positions[i] - shift,
                color: hasColor ? colors![i] : SIMD4<Float>(0.5, 0.5, 0.5, 1.0),
                intensity: hasInt ? intensities![i] : 1.0,
                scanAngle: hasAngle ? scanAngles![i] : 0.0,
                returnNumber: hasReturn ? returnNumbers![i] : 1.0,
                timeStamp: hasTime ? timeStamps![i] : Float(i) / Float(max(n - 1, 1))
            ))
        }

        self.vertices = vertices
        self.minBounds = positions.isEmpty ? .zero : minB - shift
        self.maxBounds = positions.isEmpty ? .zero : maxB - shift
        self.hasColors = colors != nil
        self.hasIntensity = intensities != nil
        self.fileName = fileName
        self.worldOrigin = origin + SIMD3<Double>(Double(shift.x), Double(shift.y), Double(shift.z))
    }

    /// Create a test point cloud (sphere of points)
    static func testSphere(pointCount: Int = 50_000) -> PointCloud {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []

        positions.reserveCapacity(pointCount)
        colors.reserveCapacity(pointCount)

        for _ in 0..<pointCount {
            // Random point on unit sphere using rejection sampling
            var p: SIMD3<Float>
            repeat {
                p = SIMD3<Float>(
                    Float.random(in: -1...1),
                    Float.random(in: -1...1),
                    Float.random(in: -1...1)
                )
            } while length(p) > 1

            // Normalize to surface
            let surfacePoint = normalize(p) * 2.0
            positions.append(surfacePoint)

            // Color based on position
            let color = SIMD4<Float>(
                (surfacePoint.x + 2) / 4,
                (surfacePoint.y + 2) / 4,
                (surfacePoint.z + 2) / 4,
                1.0
            )
            colors.append(color)
        }

        return PointCloud(positions: positions, colors: colors, fileName: "Test Sphere")
    }

    /// Create a test cube point cloud
    static func testCube(pointCount: Int = 10_000) -> PointCloud {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []

        positions.reserveCapacity(pointCount)
        colors.reserveCapacity(pointCount)

        for _ in 0..<pointCount {
            let x = Float.random(in: -1...1)
            let y = Float.random(in: -1...1)
            let z = Float.random(in: -1...1)

            positions.append(SIMD3<Float>(x, y, z))

            let color = SIMD4<Float>(
                (x + 1) / 2,
                (y + 1) / 2,
                (z + 1) / 2,
                1.0
            )
            colors.append(color)
        }

        return PointCloud(positions: positions, colors: colors, fileName: "Test Cube")
    }
}

// MARK: - Helper

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - Geometry validation

extension SIMD3 where Scalar == Float {
    /// True when every component is finite.
    ///
    /// `NaN` and `inf` occur routinely in exports from scanning pipelines, and
    /// `Float("nan")` parses successfully - so without this check they reach
    /// the bounds calculation, poison it, and then trap on the `Int32`
    /// narrowing inside voxel subsampling.
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
