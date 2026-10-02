import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// Draws the application mark at every size macOS asks for.
//
// The same form the app draws on screen: a solid source point with concentric
// wavefronts leaving it. Rendered here with Core Graphics rather than exported
// from the SwiftUI Canvas so it can be regenerated from source at any time.

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let paper = srgb(0xFBFBF9)
// Ink, not the interface's mid grey. An icon has to hold up at 32px against
// a light desktop, and ink500 on paper simply disappeared there.
let ink: UInt32 = 0x141412
let core  = srgb(0x141412)

/// Rings, as (radius, opacity, weight) - the same proportions as `Mark`.
let allRings: [(CGFloat, CGFloat, CGFloat)] = [
    (0.34, 0.92, 1.00),
    (0.60, 0.62, 0.88),
    (0.90, 0.36, 0.76)
]

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The macOS icon grid: the artwork sits in a rounded square inset from the
    // canvas, not edge to edge.
    let inset = s * 0.094
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237          // Apple's continuous-corner ratio

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
    ctx.addPath(squircle)
    ctx.setFillColor(paper)
    ctx.fillPath()

    // A hairline edge, so the icon still reads as an object on a white desktop.
    ctx.addPath(squircle)
    ctx.setStrokeColor(srgb(ink, 0.14))
    ctx.setLineWidth(max(s * 0.003, 0.5))
    ctx.strokePath()

    // Below 32px three rings collapse into a grey smudge, so the mark is
    // simplified rather than reproduced faithfully at a size it cannot hold.
    let rings: [(CGFloat, CGFloat, CGFloat)]
    switch size {
    case ..<24:  rings = [allRings[1]]
    case ..<48:  rings = [allRings[0], allRings[2]]
    default:     rings = allRings
    }

    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let unit = rect.width * 0.34              // the mark, with air around it

    for (fraction, opacity, weight) in rings {
        let r = unit * fraction
        ctx.setStrokeColor(srgb(ink, opacity))
        ctx.setLineWidth(max(s * 0.016 * weight, size < 32 ? 1.0 : 1.5))
        ctx.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                     width: r * 2, height: r * 2))
    }

    let coreRadius = max(unit * 0.20, s * 0.025)
    ctx.setFillColor(core)
    ctx.fillEllipse(in: CGRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                               width: coreRadius * 2, height: coreRadius * 2))

    return ctx.makeImage()
}

// macOS wants each logical size at 1x and 2x; these are the distinct pixel
// dimensions that covers.
let sizes = [16, 32, 64, 128, 256, 512, 1024]
var written: [Int: String] = [:]

for size in sizes {
    guard let image = draw(size: size) else {
        print("FAIL  could not draw \(size)"); exit(1)
    }
    let name = "icon_\(size).png"
    let url = outputDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("FAIL  could not open \(name)"); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        print("FAIL  could not write \(name)"); exit(1)
    }
    written[size] = name
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0))\(bytes ?? 0) bytes")
}

// The catalogue, listing each idiom/scale against the file that fills it.
struct Entry { let size: Int; let scale: Int }
let entries = [Entry(size: 16, scale: 1), Entry(size: 16, scale: 2),
               Entry(size: 32, scale: 1), Entry(size: 32, scale: 2),
               Entry(size: 128, scale: 1), Entry(size: 128, scale: 2),
               Entry(size: 256, scale: 1), Entry(size: 256, scale: 2),
               Entry(size: 512, scale: 1), Entry(size: 512, scale: 2)]

var images: [String] = []
for e in entries {
    let pixels = e.size * e.scale
    guard let file = written[pixels] else {
        print("FAIL  no image for \(pixels)px"); exit(1)
    }
    images.append("""
        {
          "filename" : "\(file)",
          "idiom" : "mac",
          "scale" : "\(e.scale)x",
          "size" : "\(e.size)x\(e.size)"
        }
    """)
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: outputDir.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("\nwrote Contents.json with \(entries.count) entries")
