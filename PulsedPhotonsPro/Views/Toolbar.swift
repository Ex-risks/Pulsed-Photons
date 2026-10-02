import SwiftUI

/// The bar. Every control in the application lives here.
///
/// One line of type, set across the full width of the sheet:
///
///     FILE.LAS (5.9M)    SOLID HEIGHT INTENSITY RGB    SIZE POINTS XRAY SECTION
///         TOP FRONT SIDE ISO    LEVEL TURN SELECT RESTORE    FIT GRID SUMI EXPORT
///
/// It reads left to right in the order of the work: what the file is, what
/// colours it, how it is drawn, where you stand, what is done to it, and the
/// sheet it ends up on.
///
/// Grouping is carried by interval alone - no rules, no panels, no zones pushed
/// to the edges. Items of one idea sit a fixed narrow gap apart; the gaps
/// *between* ideas are elastic and share out whatever width is left, so the
/// line always spans the sheet and the categories stay evenly distributed at
/// any window size. Fixed inside, elastic between: that is the whole system.
///
/// Every category holds exactly four items. The line then has one rhythm rather
/// than a run of pairs and a stray triple, and each group is a shape the eye
/// can take in whole. Where a category was short it gained the control that
/// genuinely belonged to it - RESTORE beside SELECT, which is its inverse.
struct ToolbarView: View {
    @ObservedObject var viewModel: ViewModel

    /// The one interval ratio in the interface. Everything else follows from it.
    private let withinGroup = Theme.Space.m      // 12
    private let betweenGroups = Theme.Space.xl   // 24

    /// Minimum subsample level (10K points or 1% of total, capped to valid range)
    private var minSubsampleLevel: Float {
        guard viewModel.originalPointCount > 0 else { return 0.01 }
        let total = Float(viewModel.originalPointCount)
        let minPoints = Float(Renderer.minimumDisplayPoints)
        return min(max(minPoints / total, 0.01), 0.99)
    }

    var body: some View {
        // Equal spacers, so the leftover width is shared out evenly and the
        // categories are distributed across the sheet rather than huddled in
        // the middle. `minLength` keeps a floor under them in a narrow window,
        // where the line packs up instead of overlapping.
        HStack(spacing: 0) {
            subject
            Spacer(minLength: betweenGroups)
            channel
            Spacer(minLength: betweenGroups)
            render
            Spacer(minLength: betweenGroups)
            view
            Spacer(minLength: betweenGroups)
            model
            Spacer(minLength: betweenGroups)
            sheet
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    // MARK: - What it is

    /// The file, and how large it is.
    ///
    /// Held to a fixed width once a file is open, so the rest of the line does
    /// not slide sideways when a longer name replaces a shorter one. Absent
    /// entirely before that, rather than reserving an empty indent on a sheet
    /// that has nothing in it yet.
    private var subject: some View {
        Group {
            if let name = viewModel.fileName {
                HStack(spacing: Theme.Space.xs) {
                    Text(name)
                        .foregroundColor(Theme.ink500)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // The count belongs to the file, not to the density control:
                    // it says how large the thing is, not how much of it is
                    // currently drawn.
                    if viewModel.originalPointCount > 0 {
                        Text("(\(Self.count(viewModel.originalPointCount)))")
                            .foregroundColor(Theme.ink300)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.Text.word)
                .tracking(Theme.Text.tracking)
                .frame(width: 190, alignment: .leading)
            }
        }
    }

    // MARK: - What colours it

    /// Availability is carried by the mode's own emphasis: a channel the file
    /// does not contain is set faint. Nothing is hidden - you can still select
    /// it and see the result.
    private var channel: some View {
        HStack(spacing: withinGroup) {
            ForEach(VisualizationMode.allCases) { mode in
                let available = mode.isAvailable(hasColors: viewModel.hasColors,
                                                 hasIntensity: viewModel.hasIntensity)
                Word(text: mode.name,
                     active: viewModel.visualizationMode == mode,
                     color: available ? Theme.ink500 : Theme.ink300.opacity(0.55)) {
                    viewModel.visualizationMode = mode
                }
                .help(available ? "\(mode.name) (\(mode.rawValue + 1))"
                                : "\(mode.name) — not present in this file")
            }
        }
        .fixedSize()
    }

    // MARK: - How it is drawn

    /// Four settings on the drawing itself: how big each point is, how many
    /// there are, how far you see through them, and what slice is kept. None
    /// touches the model or the camera - all four decide what reaches the eye.
    private var render: some View {
        HStack(spacing: withinGroup) {
            ScrubValue(label: "size",
                       value: $viewModel.pointSize,
                       range: 0.5...15,
                       defaultValue: 3.0,
                       format: { String(format: "%.1f", $0) })

            // An absolute count, in log space: "how many points am I looking
            // at" is the question, and a percentage of an unstated total is not
            // an answer. This is the still budget - motion drops to 3M by itself.
            ScrubValue(label: "points",
                       value: $viewModel.subsampleLevel,
                       range: minSubsampleLevel...1.0,
                       defaultValue: 1.0,
                       format: { [total = viewModel.originalPointCount] level in
                           Self.count(Int((Float(total) * level).rounded()))
                       },
                       logarithmic: true,
                       parse: { [total = viewModel.originalPointCount] text in
                           guard total > 0 else { return nil }
                           let cleaned = text.lowercased()
                               .replacingOccurrences(of: ",", with: "")
                               .trimmingCharacters(in: .whitespaces)
                           var multiplier: Float = 1
                           var digits = cleaned
                           if cleaned.hasSuffix("m") { multiplier = 1_000_000; digits.removeLast() }
                           else if cleaned.hasSuffix("k") { multiplier = 1_000; digits.removeLast() }
                           guard let n = Float(digits) else { return nil }
                           return (n * multiplier) / Float(total)
                       })

            ScrubValue(label: "xray",
                       value: $viewModel.overlayStrength,
                       range: 0...1,
                       defaultValue: 0,
                       format: { $0 <= 0 ? "off" : String(format: "%.2f", $0) })

            // Thickness in the file's own units, so a typed 0.3 means 0.3 of
            // whatever the caption says the coordinates are counted in. The
            // ceiling is the cloud's own height: a thicker band is the whole
            // cloud, which is what "off" already means.
            ScrubValue(label: "section",
                       value: $viewModel.sectionThickness,
                       range: 0...max(viewModel.verticalExtent, 0.001),
                       defaultValue: 0,
                       format: { $0 <= 0 ? "off" : Self.thickness($0) },
                       helpText: "Section: drag to set the thickness of the cut, "
                               + "pan to move it up and down, ⌥-click to clear")
        }
        .fixedSize()
    }

    // MARK: - Where you stand

    /// Words rather than glyphs. A projection glyph has to be decoded; "TOP"
    /// does not, and at this size it is barely wider.
    private var view: some View {
        HStack(spacing: withinGroup) {
            ForEach(Camera.StandardView.allCases) { standard in
                Word(text: standard.rawValue, active: viewModel.standardView == standard) {
                    viewModel.setStandardView(standard)
                }
                .help("\(standard.rawValue.capitalized) view")
            }
        }
        .fixedSize()
    }

    // MARK: - What is done to it

    /// The four operations that act on the object itself.
    ///
    /// TURN and SELECT are modes and mutually exclusive, because both take over
    /// what a drag means. RESTORE sits here because it is SELECT's inverse -
    /// the way back from a deletion - and it reads faint until there is
    /// something to undo, rather than disappearing and shifting the line.
    private var model: some View {
        HStack(spacing: withinGroup) {
            Word(text: "level") { viewModel.levelToGround() }
                .help("Level to ground — fits the ground plane and rotates it flat (L)")

            Word(text: "turn", active: viewModel.isTurning,
                 color: viewModel.isTurning ? Theme.seal : Theme.ink500) {
                viewModel.isTurning.toggle()
                if viewModel.isTurning { viewModel.isSelectionMode = false }
            }
            .help("Turn the model — drag a ring to rotate, shift to snap to 15°, "
                  + "⌥-click here to reset (T)")
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded {
                viewModel.resetTurn()
            })

            Word(text: "select", active: viewModel.isSelectionMode,
                 color: viewModel.isSelectionMode ? Theme.seal : Theme.ink500) {
                viewModel.isSelectionMode.toggle()
                if viewModel.isSelectionMode { viewModel.isTurning = false }
                if !viewModel.isSelectionMode { viewModel.clearSelection() }
            }
            .help("Selection mode (S)")

            Word(text: "restore",
                 color: viewModel.hasEdits ? Theme.ink500 : Theme.ink300.opacity(0.55)) {
                guard viewModel.hasEdits else { return }
                viewModel.restoreOriginal()
            }
            .help(viewModel.hasEdits
                  ? "Restore every deleted point"
                  : "Restore — nothing has been deleted")
        }
        .fixedSize()
    }

    // MARK: - The sheet

    /// The four things that belong to the page rather than to the model: how
    /// much of it the frame holds, what it is read against, what it is drawn
    /// on, and how it leaves.
    ///
    /// FIT sits here rather than with the viewpoints because those four are
    /// *directions* and this is *extent* - a different question, asked of the
    /// sheet rather than of where you are standing.
    private var sheet: some View {
        HStack(spacing: withinGroup) {
            Word(text: "fit") { viewModel.fitToBounds() }
                .help("Fit to bounds (F)")

            // The grid states its own spacing, which is the whole of its
            // interface: the value adapts to the zoom, so there is nothing to
            // set beyond whether it is there.
            Word(text: viewModel.showGrid ? "grid \(Self.spacing(viewModel.gridSpacing))" : "grid",
                 active: viewModel.showGrid) {
                viewModel.showGrid.toggle()
            }
            .help(viewModel.showGrid
                  ? "Ground grid at \(Self.spacing(viewModel.gridSpacing)) per cell, "
                    + "in the units named beside the file (G)"
                  : "Ground grid, to scale (G)")

            // These two were the last glyphs. A drawn mark earns its place only
            // when it is faster to read than its name, and neither was: both
            // still needed a tooltip to be certain of, which is a word arriving
            // late.
            Word(text: "sumi", active: viewModel.isDarkMode) {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.isDarkMode.toggle() }
            }
            .help("Sumi ground — dark paper")

            // The same door as File ▸ Export…, not a shortcut past it. Two
            // routes to one panel; there is no way to reach an export the other
            // route cannot offer.
            Word(text: "export", active: viewModel.isExporting) {
                viewModel.isExporting = true
            }
            .help("Export — image or point cloud (⌘E)")
            .disabled(viewModel.pointCount == 0)
        }
        .fixedSize()
    }

    // MARK: - Formatting

    /// Precision follows magnitude, so a 0.15 band and a 40 band both read
    /// without a wall of trailing zeros.
    private static func thickness(_ v: Float) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    /// Grid spacing is always a 1-2-5 round number, so it never needs decimals
    /// above 1 and never more than two below.
    private static func spacing(_ v: Float) -> String {
        guard v.isFinite, v > 0 else { return "-" }
        if v >= 1 { return String(format: "%.0f", v) }
        if v >= 0.1 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func count(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// Bounding size of the loaded cloud, in the file's own units. Precision is
    /// chosen once from the largest component so a triple reads consistently.
    static func extent(_ e: SIMD3<Float>) -> String {
        let largest = max(e.x, max(e.y, e.z))
        let digits = largest >= 100 ? 0 : (largest >= 10 ? 1 : 2)
        func f(_ v: Float) -> String { String(format: "%.\(digits)f", v) }
        return "\(f(e.x)) × \(f(e.y)) × \(f(e.z))"
    }
}
