import SwiftUI
import AppKit
import simd

/// Design tokens.
///
/// The application is a sheet of paper; the point cloud is the drawing. The
/// entire interface is one line of typography that appears when reached for
/// and withdraws when not. One type size, two weights, one accent. Hierarchy
/// is carried by ink value alone.
enum Theme {

    // MARK: - Colour

    /// Values are given as (light, dark) pairs and resolved per appearance, so
    /// views never branch on the current theme.
    private static func dynamic(light: SIMD3<Double>, dark: SIMD3<Double>) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark))
    }

    private static func nsDynamic(light: SIMD3<Double>, dark: SIMD3<Double>) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        }
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 0xFF) / 255,
              Double((hex >> 8) & 0xFF) / 255,
              Double(hex & 0xFF) / 255)
    }

    // Ground. White with warmth barely below the threshold of naming - not a
    // beige you can point to. Dark is sumi, not gray.
    static let paperLight = rgb(0xFBFBF9)
    static let paperDark  = rgb(0x0E0E0D)
    static let paper = dynamic(light: paperLight, dark: paperDark)

    // Ink. Named by how much presence a mark carries.
    static let ink900Light = rgb(0x141412)   // the points; the active word
    static let ink900Dark  = rgb(0xF4F3F0)

    /// The active mode and a value while it is being scrubbed.
    static let ink900 = dynamic(light: ink900Light, dark: ink900Dark)
    /// A value's label while scrubbing; secondary emphasis.
    static let ink700 = dynamic(light: rgb(0x3A3936), dark: rgb(0xC9C7C2))
    /// Every clickable word.
    static let ink500 = dynamic(light: rgb(0x71706B), dark: rgb(0x8E8C86))
    /// Values, metadata, the scale bar.
    static let ink300 = dynamic(light: rgb(0xB4B2AC), dark: rgb(0x4E4D48))

    /// The one accent on the page: seal red. Selection and deletion only.
    static let seal = dynamic(light: rgb(0xA63A2E), dark: rgb(0xD25A4C))

    /// Point colour for the modes that do not carry their own.
    static func pointColor(isDarkMode: Bool) -> SIMD4<Float> {
        let c = isDarkMode ? ink900Dark : ink900Light
        return SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), 1)
    }

    /// The ground grid. Faint enough to be read past rather than looked at -
    /// it is the surface the drawing stands on, not part of the drawing. The
    /// alpha here is for the emphasised lines; the rest carry a third of it.
    static func gridColor(isDarkMode: Bool) -> SIMD4<Float> {
        // The same values ink500 is built from. Metal needs the components, not
        // a dynamic Color, so they are restated rather than resolved.
        let c = isDarkMode ? rgb(0x8E8C86) : rgb(0x71706B)
        return SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), 0.34)
    }

    /// The signature stamped into exported images, resolved for the theme the
    /// image was rendered in.
    static func exportMarkColor(isDarkMode: Bool) -> NSColor {
        let c = isDarkMode ? rgb(0x4E4D48) : rgb(0xB4B2AC)
        return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }

    // MARK: - Type
    //
    // One size. Two weights. Medium appears only on the active mode and on a
    // value while it is being scrubbed; everything else is Regular, and
    // hierarchy comes from ink value.

    enum Text {
        static let size: CGFloat = 11
        static let word = Font.system(size: size, weight: .regular).smallCaps()
        static let wordActive = Font.system(size: size, weight: .medium).smallCaps()
        static let numeral = Font.system(size: size, weight: .regular).monospacedDigit().smallCaps()
        static let numeralActive = Font.system(size: size, weight: .medium).monospacedDigit().smallCaps()

        /// Small caps need more air than lowercase - the letterforms are wider
        /// and the absence of ascenders and descenders removes the rhythm that
        /// normally separates words.
        static let tracking: CGFloat = 0.7
    }

    // MARK: - Space

    enum Space {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    static let hairline: CGFloat = 1

    // MARK: - Motion
    //
    // Opacity only. Nothing slides, scales or bounces.

    enum Motion {
        static let inkChange: Double = 0.15
    }
}

// MARK: - The atom

/// A point with a faint concentric halo.
///
/// The application's single form. It is the logo, it is the pivot the view
/// turns around, and it is what the renderer actually draws - every splat is a
/// disc with a soft coverage rim. Identity, interface and subject are one mark
/// at different scales; everything else in the interface is line and interval.
struct Mark: View {
    var size: CGFloat = 14
    var color: Color = Theme.ink300
    var pointColor: Color = Theme.ink500

    /// A pulse: one emitted point and the wavefronts leaving it.
    ///
    /// Continuous hairline rings, not rings made of dots. The earlier mark drew
    /// each ring as a necklace of points, which described the data but mushed
    /// into grey at any size small enough to actually use. Strokes stay crisp
    /// at 14pt and at 200, which is the only test a mark has to pass.
    ///
    /// Each ring is fainter and finer than the one inside it, so the eye reads
    /// outward and the whole thing decays into paper rather than stopping at an
    /// edge. Drawn rather than imported: sharp at any size, follows the ink
    /// scale into either theme, and needs no asset.
    private let rings: [(radius: CGFloat, opacity: CGFloat, weight: CGFloat)] = [
        (0.34, 0.85, 1.00),
        (0.60, 0.50, 0.85),
        (0.90, 0.24, 0.70)
    ]

    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let unit = min(s.width, s.height) / 2

            for ring in rings {
                let r = unit * ring.radius
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(color.opacity(ring.opacity)),
                           lineWidth: max(Theme.hairline * ring.weight, 0.5))
            }

            // The source. Solid, and the only filled thing in the mark, so the
            // eye starts where the pulse does.
            let core = unit * 0.15
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core,
                                            width: core * 2, height: core * 2)),
                     with: .color(pointColor))
        }
        .frame(width: size, height: size)
    }
}

/// Corner brackets marking the drawing's frame.
///
/// Four returns rather than a closed rectangle: the frame is registration, not
/// enclosure, and the drawing is free to run past it.
struct CornerBrackets: Shape {
    var arm: CGFloat = 26

    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = min(arm, min(r.width, r.height) / 3)
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + a * CGFloat(sx), y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + a * CGFloat(sy)))
        }
        return p
    }
}

// MARK: - Word

/// A clickable word. The entire control vocabulary of the application.
struct Word: View {
    let text: String
    var active: Bool = false
    var color: Color = Theme.ink500
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(active ? Theme.Text.wordActive : Theme.Text.word)
                .tracking(Theme.Text.tracking)
                .foregroundColor(active ? Theme.ink900 : color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: Theme.Motion.inkChange), value: active)
    }
}

// MARK: - ScrubValue

/// A parameter as a word and a numeral. Drag horizontally on it to change the
/// value; double-click to reset. The full range maps to about 220 points of
/// travel. This replaces slider tracks entirely.
struct ScrubValue: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    var format: (Float) -> String

    /// Scrub in log space.
    ///
    /// For a value spanning orders of magnitude - a point budget running from
    /// ten thousand to fifty million - a linear drag buries everything below a
    /// few million in the first tenth of the travel, and the number cannot be
    /// dialled in at all. In log space each decade gets equal travel.
    var logarithmic: Bool = false

    @State private var dragStart: Float? = nil
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Parse typed input back into the value's own units. `points` is typed as
    /// a count, not a ratio, so it needs the total to convert.
    var parse: ((String) -> Float?)? = nil

    /// Replaces the generated tooltip. Needed where several numerals share one
    /// label - the TURN triple - and the label alone cannot say which axis a
    /// given numeral turns about.
    var helpText: String? = nil

    private var scrubbing: Bool { dragStart != nil }

    /// Position of `v` within the range, 0...1.
    private func normalize(_ v: Float) -> Float {
        let lo = range.lowerBound, hi = range.upperBound
        guard logarithmic, lo > 0, hi > lo else {
            return (v - lo) / max(hi - lo, .leastNormalMagnitude)
        }
        return (log(max(v, lo)) - log(lo)) / (log(hi) - log(lo))
    }

    /// Inverse of `normalize`.
    private func denormalize(_ t: Float) -> Float {
        let lo = range.lowerBound, hi = range.upperBound
        let clamped = min(max(t, 0), 1)
        guard logarithmic, lo > 0, hi > lo else {
            return lo + clamped * (hi - lo)
        }
        return exp(log(lo) + clamped * (log(hi) - log(lo)))
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(label)
                .font(Theme.Text.word)
                .tracking(Theme.Text.tracking)
                .foregroundColor(scrubbing || editing ? Theme.ink700 : Theme.ink500)

            if editing {
                // Typed entry, for when a value has to be exact rather than
                // found by feel.
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.numeralActive)
                    .foregroundColor(Theme.ink900)
                    .frame(width: 56)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                Text(format(value))
                    .font(scrubbing ? Theme.Text.numeralActive : Theme.Text.numeral)
                    .foregroundColor(scrubbing ? Theme.ink900 : Theme.ink300)
            }
        }
        .contentShape(Rectangle())
        // Double-tap must win outright, and must stop competing once the field
        // is open.
        //
        // Previously the drag was attached on its own with a 1pt threshold, so
        // it claimed the interaction on the first pixel of movement and a
        // double-click almost never landed - and while editing it still sat
        // over the text field and swallowed the clicks that would focus it.
        // `.exclusively` settles the precedence; `including: .subviews` hands
        // events to the field while it is open.
        .gesture(
            TapGesture(count: 2)
                .onEnded { beginEditing() }
                .exclusively(before:
                    DragGesture(minimumDistance: 3)
                        .onChanged { gesture in
                            if dragStart == nil { dragStart = value }
                            // Travel is measured in normalized space, so a
                            // logarithmic control gives each decade equal drag.
                            let start = normalize(dragStart!)
                            let moved = start + Float(gesture.translation.width) / 220
                            let next = denormalize(moved)
                            value = min(max(next, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in dragStart = nil }
                ),
            including: editing ? .subviews : .all
        )
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded {
            value = defaultValue
        })
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .help(helpText ?? "\(label): drag to change, double-click to type, ⌥-click to reset")
    }

    private func beginEditing() {
        draft = format(value)
        editing = true
        // The field has to exist before it can take focus.
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        defer { editing = false }
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard let parsed = parse?(text) ?? Float(text) else { return }
        value = min(max(parsed, range.lowerBound), range.upperBound)
    }
}
