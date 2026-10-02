import Foundation

// Stubs for the two symbols LASParser reaches for outside the Parsers folder.
func ppLog(_ message: @autoclosure () -> String) { }

enum ParserError: LocalizedError {
    case invalidData
    case readError(String)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "invalid"
        case .readError(let m): return m
        }
    }
}

// MARK: - Synthetic LAS construction
//
// Ground truth is authored here, so a pass means the reader agrees with a file
// whose declaration is known by construction rather than by another tool.

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
func leDouble(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }

func geoKeyVLR(unitCode: UInt16, tagLocation: UInt16 = 0) -> [UInt8] {
    var payload: [UInt8] = []
    payload += le16(1)            // KeyDirectoryVersion
    payload += le16(1)            // KeyRevision
    payload += le16(0)            // MinorRevision
    payload += le16(2)            // NumberOfKeys
    // A leading unrelated key, so the walk has to actually search.
    payload += le16(1024) + le16(0) + le16(1) + le16(1)      // GTModelType
    payload += le16(3076) + le16(tagLocation) + le16(1) + le16(unitCode)
    return vlrHeader(recordID: 34735, length: payload.count) + payload
}

func wktVLR(_ text: String) -> [UInt8] {
    let payload = Array(text.utf8)
    return vlrHeader(recordID: 2112, length: payload.count) + payload
}

func vlrHeader(recordID: UInt16, length: Int) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 54)
    h.replaceSubrange(0..<2, with: le16(0))
    for (i, b) in Array("LASF_Projection".utf8).enumerated() { h[2 + i] = b }
    h.replaceSubrange(18..<20, with: le16(recordID))
    h.replaceSubrange(20..<22, with: le16(UInt16(length)))
    return h
}

/// A minimal but structurally valid LAS file with three points.
func makeLAS(versionMinor: UInt8,
             vlrs: [[UInt8]],
             wktFlag: Bool,
             vlrCountOverride: UInt32? = nil) -> Data {
    let headerSize = versionMinor >= 4 ? 375 : 227
    var header = [UInt8](repeating: 0, count: headerSize)

    for (i, b) in Array("LASF".utf8).enumerated() { header[i] = b }
    header.replaceSubrange(6..<8, with: le16(wktFlag ? 0x0010 : 0))
    header[24] = 1
    header[25] = versionMinor
    header.replaceSubrange(94..<96, with: le16(UInt16(headerSize)))

    let vlrBytes = vlrs.flatMap { $0 }
    let pointOffset = headerSize + vlrBytes.count
    header.replaceSubrange(96..<100, with: le32(UInt32(pointOffset)))
    header.replaceSubrange(100..<104, with: le32(vlrCountOverride ?? UInt32(vlrs.count)))
    header[104] = 0                                    // point format 0
    header.replaceSubrange(105..<107, with: le16(20))  // record length
    header.replaceSubrange(107..<111, with: le32(3))   // legacy point count

    header.replaceSubrange(131..<139, with: leDouble(0.001))
    header.replaceSubrange(139..<147, with: leDouble(0.001))
    header.replaceSubrange(147..<155, with: leDouble(0.001))
    header.replaceSubrange(155..<163, with: leDouble(0))
    header.replaceSubrange(163..<171, with: leDouble(0))
    header.replaceSubrange(171..<179, with: leDouble(0))

    if versionMinor >= 4 {
        var count = [UInt8](repeating: 0, count: 8)
        count[0] = 3
        header.replaceSubrange(247..<255, with: count)
    }

    var points: [UInt8] = []
    for i in 0..<3 {
        points += le32(UInt32(i * 1000))   // x
        points += le32(UInt32(i * 2000))   // y
        points += le32(UInt32(i * 500))    // z
        points += [UInt8](repeating: 0, count: 8)
    }

    return Data(header + vlrBytes + points)
}

// MARK: - Reading a header's declaration

func declaredUnit(of data: Data) -> LinearUnit? {
    let headerSize = Int(UInt16(data[94]) | (UInt16(data[95]) << 8))
    let vlrCount = Int(UInt32(data[100]) | (UInt32(data[101]) << 8)
                       | (UInt32(data[102]) << 16) | (UInt32(data[103]) << 24))
    let wkt = (UInt16(data[6]) | (UInt16(data[7]) << 8)) & 0x0010 != 0
    return LASParser.linearUnit(in: data, headerSize: headerSize,
                                vlrCount: vlrCount, preferWKT: wkt)
}

// MARK: - Cases

// A foot-based projected CRS still defines its ellipsoid in metres. This is the
// case the naive "search for metre" reader gets wrong.
let footWKT = """
PROJCS["NAD83 / Massachusetts Mainland (ftUS)",\
GEOGCS["NAD83",DATUM["North_American_Datum_1983",\
SPHEROID["GRS 1980",6378137,298.257222101,LENGTHUNIT["metre",1]]],\
PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],\
PROJECTION["Lambert_Conformal_Conic_2SP"],\
UNIT["US survey foot",0.304800609601219]]
"""

let intlFootWKT = """
PROJCS["Some Grid (ft)",GEOGCS["WGS 84",\
SPHEROID["WGS 84",6378137,298.257223563,LENGTHUNIT["metre",1]]],\
UNIT["foot",0.3048]]
"""

let metreWKT = """
PROJCS["WGS 84 / UTM zone 30N",GEOGCS["WGS 84",\
SPHEROID["WGS 84",6378137,298.257223563,LENGTHUNIT["metre",1]]],\
UNIT["metre",1]]
"""

struct Case {
    let name: String
    let data: Data
    let expected: LinearUnit?
}

let cases: [Case] = [
    Case(name: "geokey 9001 metre",
         data: makeLAS(versionMinor: 2, vlrs: [geoKeyVLR(unitCode: 9001)], wktFlag: false),
         expected: LinearUnit(kind: .metre, isDeclared: true)),

    Case(name: "geokey 9002 int. foot",
         data: makeLAS(versionMinor: 2, vlrs: [geoKeyVLR(unitCode: 9002)], wktFlag: false),
         expected: LinearUnit(kind: .foot, isDeclared: true)),

    Case(name: "geokey 9003 US survey foot",
         data: makeLAS(versionMinor: 2, vlrs: [geoKeyVLR(unitCode: 9003)], wktFlag: false),
         expected: LinearUnit(kind: .usSurveyFoot, isDeclared: true)),

    Case(name: "no VLRs at all",
         data: makeLAS(versionMinor: 2, vlrs: [], wktFlag: false),
         expected: nil),

    Case(name: "geokey value held in another tag",
         data: makeLAS(versionMinor: 2, vlrs: [geoKeyVLR(unitCode: 9001, tagLocation: 34736)],
                       wktFlag: false),
         expected: nil),

    Case(name: "WKT US survey foot (ellipsoid in metres)",
         data: makeLAS(versionMinor: 4, vlrs: [wktVLR(footWKT)], wktFlag: true),
         expected: LinearUnit(kind: .usSurveyFoot, isDeclared: true)),

    Case(name: "WKT international foot (ellipsoid in metres)",
         data: makeLAS(versionMinor: 4, vlrs: [wktVLR(intlFootWKT)], wktFlag: true),
         expected: LinearUnit(kind: .foot, isDeclared: true)),

    Case(name: "WKT metre",
         data: makeLAS(versionMinor: 4, vlrs: [wktVLR(metreWKT)], wktFlag: true),
         expected: LinearUnit(kind: .metre, isDeclared: true)),

    Case(name: "WKT flag set but only geokeys present",
         data: makeLAS(versionMinor: 4, vlrs: [geoKeyVLR(unitCode: 9002)], wktFlag: true),
         expected: LinearUnit(kind: .foot, isDeclared: true)),

    Case(name: "geokeys after an unrelated VLR",
         data: makeLAS(versionMinor: 2,
                       vlrs: [vlrHeader(recordID: 1234, length: 16) + [UInt8](repeating: 7, count: 16),
                              geoKeyVLR(unitCode: 9003)],
                       wktFlag: false),
         expected: LinearUnit(kind: .usSurveyFoot, isDeclared: true)),

    // Robustness: a count that runs past the end of the file must stop, not trap.
    Case(name: "corrupt VLR count (999)",
         data: makeLAS(versionMinor: 2, vlrs: [geoKeyVLR(unitCode: 9001)],
                       wktFlag: false, vlrCountOverride: 999),
         expected: LinearUnit(kind: .metre, isDeclared: true)),
]

var failures = 0
print("synthetic files")
for c in cases {
    let got = declaredUnit(of: c.data)
    let ok = got == c.expected
    if !ok { failures += 1 }
    let describe: (LinearUnit?) -> String = { $0.map { "\($0.kind.rawValue)" } ?? "undeclared" }
    print("  \(ok ? "pass" : "FAIL")  \(c.name.padding(toLength: 44, withPad: " ", startingAt: 0))"
          + "expected \(describe(c.expected)), got \(describe(got))")
}

// MARK: - Real files, header only

// Real files, when there are any to hand.
//
// Deliberately not a list of absolute paths: this ran against a local scan
// collection and hard-coded someone's home directory into the repository.
// Point PP_LAS_DIR at a folder of scans to exercise it, or drop them in
// Samples/. With neither, the synthetic cases above still cover the parser.
let sampleDirs = [ProcessInfo.processInfo.environment["PP_LAS_DIR"],
                  "Samples"].compactMap { $0 }

let realFiles: [String] = sampleDirs.flatMap { dir -> [String] in
    let url = URL(fileURLWithPath: dir)
    let found = (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil)) ?? []
    return found.filter { $0.pathExtension.lowercased() == "las" }.map(\.path)
}

print(realFiles.isEmpty
      ? "\nreal files: none found (set PP_LAS_DIR to test against your own)"
      : "\nreal files")
for path in realFiles {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 227 else {
        print("  --    \(url.lastPathComponent): unreadable")
        continue
    }
    let versionMinor = data[25]
    let vlrCount = Int(UInt32(data[100]) | (UInt32(data[101]) << 8)
                       | (UInt32(data[102]) << 16) | (UInt32(data[103]) << 24))
    let unit = declaredUnit(of: data)
    let name = url.lastPathComponent.padding(toLength: 24, withPad: " ", startingAt: 0)
    print("  \(name) LAS 1.\(versionMinor), \(vlrCount) VLR(s) -> "
          + (unit.map { "\($0.kind.name) (declared)" } ?? "undeclared, will assume metres"))
}

print(failures == 0 ? "\nall synthetic cases pass" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
