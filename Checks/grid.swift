import Foundation
import simd

// The grid's whole interface is a toggle, which only works if the spacing rule
// holds by itself over every scale a scan might be viewed at - a 2m room and a
// 20km flight line - and always lands on a number a person would write down.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failures += 1 }
    print("  \(ok ? "pass" : "FAIL")  \(name.padding(toLength: 44, withPad: " ", startingAt: 0))\(detail)")
}

func niceSpacing(targetWorld: Float) -> Float {
    guard targetWorld.isFinite, targetWorld > 0 else { return 1 }
    let exponent = floor(log10(targetWorld))
    let base = targetWorld / pow(10, exponent)
    let nice: Float = base < 1.5 ? 1 : (base < 3.5 ? 2 : (base < 7.5 ? 5 : 10))
    return nice * pow(10, exponent)
}

/// Mantissa of a 1-2-5 number, to check it is one of those and nothing else.
func mantissa(_ v: Float) -> Int {
    let e = floor(log10(Double(v)))
    return Int((Double(v) / pow(10, e)).rounded())
}

print("cells stay legible across nine decades of zoom")
do {
    var worstLow = Float.greatestFiniteMagnitude, worstHigh: Float = 0
    var badRounding: [Float] = []
    var worldHeight: Float = 0.01
    var samples = 0

    while worldHeight < 100_000 {
        let s = niceSpacing(targetWorld: worldHeight / 10)
        let cells = worldHeight / s              // cells spanning the viewport
        worstLow = min(worstLow, cells)
        worstHigh = max(worstHigh, cells)
        if ![1, 2, 5, 10].contains(mantissa(s)) { badRounding.append(s) }
        samples += 1
        worldHeight *= 1.07                      // ~100 steps per decade
    }

    check("every spacing is a 1-2-5 round number", badRounding.isEmpty,
          badRounding.isEmpty ? "\(samples) zoom levels" : "bad: \(badRounding.prefix(4))")
    check("never fewer than 5 cells on screen", worstLow >= 5,
          "min \(String(format: "%.1f", worstLow))")
    check("never more than 20 cells on screen", worstHigh <= 20,
          "max \(String(format: "%.1f", worstHigh))")
}

print("\nwhat it picks at real scales")
for (name, h) in [("a room, 3m", Float(3)), ("a house, 12m", 12),
                  ("a courtyard, 60m", 60), ("a block, 300m", 300),
                  ("a flight line, 4km", 4000)] {
    let s = niceSpacing(targetWorld: h / 10)
    print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))"
          + "\(s) per cell, \(String(format: "%.0f", h / s)) cells across")
}

print("\ndegenerate input")
do {
    check("zero falls back to 1", niceSpacing(targetWorld: 0) == 1)
    check("negative falls back to 1", niceSpacing(targetWorld: -5) == 1)
    check("nan falls back to 1", niceSpacing(targetWorld: .nan) == 1)
    check("infinity falls back to 1", niceSpacing(targetWorld: .infinity) == 1)
}

print(failures == 0 ? "\nall grid cases pass" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
