import SwiftUI
import MetalKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: ViewModel

    var body: some View {
        GeometryReader { geo in
        ZStack {
            // The drawing
            MetalView(viewModel: viewModel)
                .ignoresSafeArea()

            if let rect = viewModel.selectionRect {
                SelectionRectangleView(rect: rect)
            }

            // Beyond the brackets the drawing recedes.
            //
            // The cloud runs past the frame on every side, which is what makes
            // the frame read as an aperture - but it would also run under the
            // controls and swallow them. A paper-coloured falloff at the edges
            // keeps the drawing subordinate to the interface without cropping
            // it, and without a panel anywhere.
            edgeFalloff
                .allowsHitTesting(false)

            emptyState

            reticle(in: geo.size)

            // The handles and the cut. Drawing only - the drag that turns
            // the model is routed through the pan gesture, so a press that
            // misses a handle still orbits.
            ModelOverlay(viewModel: viewModel, clock: viewModel.cameraClock)
                .allowsHitTesting(false)

            // The mount.
            //
            // A hairline aperture that the drawing bleeds past on three sides,
            // so it reads as a window onto something larger rather than a box
            // containing it. Inside the mount go the things belonging to this
            // drawing - its name, its maker, its measure, and how you are
            // looking at it. Outside, below, go the operations.
            VStack(spacing: 0) {
                ZStack {
                    mountContents(canvas: geo.size)
                    CornerBrackets()
                        .stroke(Theme.ink300.opacity(0.7), lineWidth: Theme.hairline)
                        .allowsHitTesting(false)
                    progressEdge
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)

                Group {
                    if let message = viewModel.errorMessage {
                        errorLine(message)
                    } else if let fraction = viewModel.progress {
                        progressLine(fraction)
                    } else {
                        ToolbarView(viewModel: viewModel)
                    }
                }
                .background(Theme.paper)
            }

            // Anything the application says at length, said in its own hand.
            if viewModel.isExporting {
                ExportSheet(viewModel: viewModel)
            } else if viewModel.isShowingAbout {
                AboutSheet(viewModel: viewModel)
            }
        }
        }
        .animation(.easeOut(duration: 0.14), value: viewModel.isExporting)
        .animation(.easeOut(duration: 0.14), value: viewModel.isShowingAbout)
        .background(Theme.paper)
        .preferredColorScheme(viewModel.effectiveDarkGround ? .dark : .light)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        // Double-clicking a scan in Finder, or dropping one on the Dock icon.
        // Without this the document types declared in Info.plist would launch
        // the app and then do nothing, which is worse than not declaring them.
        .onOpenURL { url in
            Task { @MainActor in
                await viewModel.loadFile(url: url, adding: viewModel.pointCount > 0)
            }
        }
        .onKeyPress { key in
            handleKeyPress(key)
        }
    }

    /// Paper reasserting itself at the four edges.
    private var edgeFalloff: some View {
        let inset = Theme.Space.xl
        return ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [Theme.paper, Theme.paper.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: inset * 2.2)
                Spacer()
                LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: inset * 2.2)
            }
            HStack(spacing: 0) {
                LinearGradient(colors: [Theme.paper, Theme.paper.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: inset * 2.2)
                Spacer()
                LinearGradient(colors: [Theme.paper.opacity(0), Theme.paper],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: inset * 2.2)
            }
        }
    }

    // MARK: - Reticle

    /// A small open crosshair at the orbit pivot.
    ///
    /// Orbiting is otherwise opaque: the model swings and you cannot tell what
    /// it is swinging around. Marking the pivot makes rotation legible, and
    /// makes panning legible too, since the pivot is what pans. Open at the
    /// centre so it never obscures the point it marks.
    private func reticle(in size: CGSize) -> some View {
        Group {
            if viewModel.isInteracting,
               viewModel.pointCount > 0,
               let p = viewModel.pivotScreenPosition(in: size) {
                // The same mark as the logo: what the view turns around is
                // marked with the application's own atom.
                Mark(size: 22, color: Theme.ink500, pointColor: Theme.ink700)
                    .position(p)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: viewModel.isInteracting)
    }

    // MARK: - Empty state

    /// The one moment the page may speak at its centre: vast emptiness, and an
    /// invitation set low on the sheet. Doubles as the only instruction the
    /// scrub numerals get, offered at the only moment instruction is welcome.
    private var emptyState: some View {
        Group {
            if viewModel.pointCount == 0 && !viewModel.isLoading {
                GeometryReader { geo in
                    VStack(spacing: Theme.Space.m) {
                        Text("drop a point cloud")
                            .foregroundColor(Theme.ink500)
                        VStack(spacing: Theme.Space.xs) {
                            Text("ply · xyz · txt · las")
                            Text("drag numbers to change them · s to select")
                        }
                        .foregroundColor(Theme.ink300)
                    }
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.6)
                }
                .transition(.opacity)
                .animation(.easeOut(duration: 0.3), value: viewModel.pointCount)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Selection

    /// The one red thing. Visible regardless of chrome state, because selection
    /// is a mode you are in, not a control you reach for.
    private var selectionStatus: some View {
        Group {
            if viewModel.hasSelection {
                HStack(spacing: Theme.Space.m) {
                    Text("\(viewModel.selectedCount.formatted()) selected")
                        .font(Theme.Text.numeral)
                        .foregroundColor(Theme.seal)
                    Word(text: "delete", color: Theme.seal) {
                        viewModel.deleteSelectedPoints()
                    }
                    Word(text: "✕", color: Theme.seal) {
                        viewModel.clearSelection()
                        viewModel.isSelectionMode = false
                    }
                    .help("Clear selection (Esc)")
                }
            } else if viewModel.isSelectionMode {
                Text("selecting")
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .foregroundColor(Theme.seal)
                    .help("Drag to select · S to leave")
            }
        }
    }

    // MARK: - Reading / error

    /// Takes the line's place while something long is happening, in the same
    /// register as the rest of the interface: words and a numeral.
    private func progressLine(_ fraction: Double) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(viewModel.progressLabel ?? "working")
                .font(Theme.Text.word)
                .tracking(Theme.Text.tracking)
                .foregroundColor(Theme.ink500)

            Text("\(Int(fraction * 100))%")
                .font(Theme.Text.numeral)
                .foregroundColor(Theme.ink700)

            if let detail = viewModel.progressDetail {
                Text("·  " + detail)
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    /// Everything that belongs to the drawing rather than to the application.
    ///
    /// Two rails run down the inside of the mount: presentation on the left,
    /// viewpoint on the right. That division is why the appearance glyph has a
    /// home here rather than being crowded in with the verbs.
    private func mountContents(canvas canvasSize: CGSize) -> some View {
        VStack(spacing: 0) {
            // The logo is the only thing outside the bar.
            HStack {
                Spacer()
                Mark(size: 26, color: Theme.ink500, pointColor: Theme.ink700)
            }

            Spacer()

            HStack(alignment: .bottom) {
                if viewModel.pointCount > 0 {
                    ScaleBarView(visibleWorldHeight: viewModel.visibleWorldHeight,
                                 canvasSize: canvasSize,
                                 isOrthographic: viewModel.isOrthographic,
                                 unit: viewModel.units)
                }
                Spacer()
                selectionStatus
            }
        }
        .padding(Theme.Space.l)
    }


    /// The sheet names its subject, then states what it is.
    ///
    /// A dashed placeholder stands where the caption will be, so the corner is
    /// composed before a file arrives rather than empty and then suddenly full.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let name = viewModel.fileName {
                Text(name)
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .foregroundColor(Theme.ink500)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ForEach(viewModel.datasetSummary, id: \.self) { line in
                    Text(line)
                        .font(Theme.Text.numeral)
                        .foregroundColor(Theme.ink300)
                }

                unitStatement
            } else {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.ink300.opacity(0.45),
                                  style: StrokeStyle(lineWidth: Theme.hairline, dash: [2, 3]))
                    .frame(width: 210, height: 52)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
    }

    /// What the coordinates are counted in. Click to state it.
    ///
    /// LAS geometry is already true to scale - the header's scale factor sees
    /// to that - so this is not a conversion, it is a label. But a label that
    /// every measurement and the grid both inherit, so its honesty matters:
    /// an *assumed* unit is set in parentheses, which is the drafting
    /// convention for a reference value, and reads as an assumption without
    /// needing a colour to be noticed or a tooltip to be decoded.
    private var unitStatement: some View {
        Button {
            viewModel.cycleUnit()
        } label: {
            Text(viewModel.units.isDeclared ? viewModel.units.kind.name
                                            : "(\(viewModel.units.kind.name))")
                .font(Theme.Text.numeral)
                .foregroundColor(Theme.ink300.opacity(viewModel.units.isDeclared ? 1 : 0.55))
        }
        .buttonStyle(.plain)
        .help(viewModel.units.isDeclared
              ? "Coordinates are in \(viewModel.units.kind.name). Click to change."
              : "This file declares no coordinate system. Assuming \(viewModel.units.kind.name) — click to state the unit.")
    }

    /// The mount's lower edge, which fills as work proceeds. Rather than adding
    /// an element, the line that bounds the drawing takes on a second job.
    private var progressEdge: some View {
        GeometryReader { geo in
            if let fraction = viewModel.progress {
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Theme.ink500)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1),
                               height: Theme.hairline)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func errorLine(_ message: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(message)
                .font(Theme.Text.word)
                .tracking(Theme.Text.tracking)
                .foregroundColor(Theme.seal)
                .lineLimit(1)
            Spacer()
            Word(text: "✕", color: Theme.seal) {
                viewModel.errorMessage = nil
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.m)
    }

    // MARK: - File Drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Only the first item: concurrent loads would interleave into the same
        // renderer state.
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            if let error = error {
                ppLog("ERROR: could not get URL from drop: \(error.localizedDescription)")
                return
            }
            guard let url = url else { return }

            Task { @MainActor in
                await self.viewModel.loadFile(url: url)
            }
        }
        return true
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
        // Number keys select a visualization mode, in line order.
        if let digit = Int(key.characters), digit >= 1, digit <= VisualizationMode.allCases.count {
            let mode = VisualizationMode.allCases[digit - 1]
            Task { @MainActor in
                viewModel.visualizationMode = mode
            }
            return .handled
        }

        switch key.characters {
        case "r":
            Task { @MainActor in viewModel.resetCamera() }
            return .handled
        case "f":
            Task { @MainActor in viewModel.fitToBounds() }
            return .handled
        case "s":
            Task { @MainActor in
                viewModel.isSelectionMode.toggle()
                if !viewModel.isSelectionMode { viewModel.clearSelection() }
            }
            return .handled
        case "\u{7F}", "\u{08}": // Delete or Backspace
            if viewModel.hasSelection {
                Task { @MainActor in viewModel.deleteSelectedPoints() }
                return .handled
            }
            return .ignored
        case "\u{1B}": // Escape
            Task { @MainActor in
                viewModel.clearSelection()
                viewModel.isSelectionMode = false
            }
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Scale bar

/// A hairline of known world length, with the magnitude beneath it. The one
/// permanent mark besides the drawing itself: it is information about the
/// drawing, not chrome.
///
/// Deliberately unitless. LAS records its coordinate system in VLRs this app
/// does not yet parse, and PLY and XYZ carry no unit information at all - so
/// labelling this "m" would be a guess presented as a measurement.
/// A sheet in the application's own hand.
///
/// System menus and system alerts are the two places an interface like this
/// usually breaks character - they arrive in Aqua, with their own type, their
/// own rules and their own idea of hierarchy. Anything the application wants to
/// say at length is said here instead: paper, corner brackets, one line of type
/// per idea, dismissed by clicking away from it.
struct Sheet<Content: View>: View {
    let title: String
    let content: Content
    let dismiss: () -> Void

    init(title: String, dismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.dismiss = dismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Paper thrown over the drawing, rather than a shadowed card
            // floating above it. Clicking it dismisses, so there is no need for
            // a close control.
            Theme.paper.opacity(0.94)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(title)
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .foregroundColor(Theme.ink300)

                content

                Text("click anywhere to dismiss")
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300.opacity(0.7))
                    .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.xxl)
            .frame(minWidth: 380, alignment: .leading)
            .overlay(
                CornerBrackets(arm: 14)
                    .stroke(Theme.ink300.opacity(0.7), lineWidth: Theme.hairline)
            )
        }
        .transition(.opacity)
    }
}

/// Where the drawing goes when it leaves.
///
/// One panel for both kinds of export, because they are the same decision: an
/// image is a view of the cloud and a file is the cloud itself, and which one
/// you want is the first thing to choose, not something buried in two different
/// menus.
struct ExportSheet: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        Sheet(title: "export", dismiss: { viewModel.isExporting = false }) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {

                // The image: a view of the cloud, at a chosen size.
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("image")
                        .font(Theme.Text.word)
                        .tracking(Theme.Text.tracking)
                        .foregroundColor(Theme.ink500)

                    HStack(spacing: Theme.Space.m) {
                        ForEach([1, 2, 3, 4], id: \.self) { scale in
                            Word(text: "\(scale)×",
                                 active: Int(viewModel.exportScale) == scale) {
                                viewModel.exportScale = CGFloat(scale)
                            }
                        }
                        Spacer(minLength: Theme.Space.l)
                        Word(text: "png · jpeg") {
                            viewModel.isExporting = false
                            viewModel.exportImage()
                        }
                    }
                }

                // The cloud itself, converted.
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("point cloud")
                        .font(Theme.Text.word)
                        .tracking(Theme.Text.tracking)
                        .foregroundColor(Theme.ink500)

                    ForEach(PointCloudFormat.allCases) { format in
                        HStack(spacing: Theme.Space.m) {
                            Word(text: format.name) {
                                viewModel.isExporting = false
                                viewModel.exportCloud(format: format)
                            }
                            .frame(width: 34, alignment: .leading)

                            // What each format keeps, because the difference
                            // between them is entirely what survives the trip.
                            Text(format.summary)
                                .font(Theme.Text.numeral)
                                .foregroundColor(Theme.ink300)
                        }
                    }
                }

                Text("\(viewModel.pointCount.formatted()) points will be written")
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300)
            }
        }
    }
}

/// What the application is.
struct AboutSheet: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        Sheet(title: "about", dismiss: { viewModel.isShowingAbout = false }) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                Mark(size: 44, color: Theme.ink500, pointColor: Theme.ink700)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("pulsed photons")
                        .font(Theme.Text.wordActive)
                        .tracking(Theme.Text.tracking)
                        .foregroundColor(Theme.ink900)

                    Text("a viewer for measured light")
                        .font(Theme.Text.word)
                        .tracking(Theme.Text.tracking)
                        .foregroundColor(Theme.ink500)

                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("reads  ply · xyz · txt · las")
                        Text("writes  ply · xyz · las · png · jpeg")
                        Text("metal · \(Renderer.defaultDisplayPoints.formatted()) point ceiling")
                    }
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300)
                    .padding(.top, Theme.Space.xs)

                    // The colophon. Below the capabilities and behind a rule,
                    // because what the application is comes before who made it;
                    // and a rule rather than more interval, so this reads as a
                    // different kind of statement instead of a fourth spec line.
                    //
                    // The proper nouns keep their capitals. Everywhere else the
                    // interface is lowercase set in small caps, so an initial
                    // cap appears nowhere but here - which is what makes a name
                    // read as a signature rather than as more metadata.
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Rectangle()
                            .fill(Theme.ink300.opacity(0.5))
                            .frame(width: 28, height: Theme.hairline)
                            .padding(.bottom, Theme.Space.xs)

                        Text("Asad Khan")
                            .foregroundColor(Theme.ink500)
                        Text("2025–26")
                            .foregroundColor(Theme.ink300)

                        Text("Institute for Design Informatics")
                            .foregroundColor(Theme.ink300)
                        Text("The University of Edinburgh")
                            .foregroundColor(Theme.ink300)
                    }
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .padding(.top, Theme.Space.m)
                }
            }
        }
    }
}

/// What the model is being done to, drawn in the scene.
///
/// Two things live here: the rotation handles and the section cut. Both are
/// world-fixed - the model turns against them - and both are drawn only while
/// they are in use, so the sheet is empty again the moment you are done.
struct ModelOverlay: View {
    @ObservedObject var viewModel: ViewModel

    /// Ticks per drawn frame. Without it these would sit still while the camera
    /// moved out from under them.
    @ObservedObject var clock: CameraClock

    var body: some View {
        Canvas { context, size in
            guard let renderer = viewModel.renderer, viewModel.pointCount > 0 else { return }
            drawSection(renderer: renderer, size: size, in: &context)
            if viewModel.isTurning {
                drawHandles(renderer: renderer, size: size, in: &context)
            }
        }
    }

    // MARK: - The handles

    /// A small gizmo in the corner: three dotted rings and a handle on each.
    ///
    /// Fixed size, and parked out of the way. Sizing the rings to the model was
    /// backwards - zooming in is precisely when you want to square a wall, and
    /// it was the moment the rings grew past the window. This cannot do that,
    /// and it never covers the thing being aligned.
    ///
    /// Dotted rather than solid, so three overlapping circles read as a sphere
    /// instead of a knot; the near half of each is drawn firmer than the far
    /// half, which is what supplies the depth. The ring being dragged goes to
    /// seal, and only its handle is filled.
    private func drawHandles(renderer: Renderer, size: CGSize,
                             in context: inout GraphicsContext) {
        let dotted = StrokeStyle(lineWidth: Theme.hairline, dash: [1.4, 3.2])
        let active = viewModel.activeTurnAxis

        for axis in 0..<3 {
            let ring = renderer.gizmoRing(axis: axis, viewSize: size)
            guard ring.count > 2 else { continue }

            let live = active == axis
            let dimmed = active != nil && !live
            let colour = live ? Theme.seal : Theme.ink500

            // Split at the horizon so the half facing away can recede.
            for (near, opacity) in [(true, 1.0), (false, 0.3)] {
                var path = Path()
                var pen = false
                for (p, depth) in ring {
                    guard (depth >= 0) == near else { pen = false; continue }
                    if pen { path.addLine(to: p) } else { path.move(to: p); pen = true }
                }
                context.stroke(path,
                               with: .color(colour.opacity(opacity * (dimmed ? 0.35 : 1))),
                               style: dotted)
            }

            // The handle: the point of the ring nearest the eye, so it is
            // always the one you can actually reach.
            if let handle = ring.max(by: { $0.depth < $1.depth })?.point {
                let r: CGFloat = live ? 3.5 : 2.5
                context.fill(Path(ellipseIn: CGRect(x: handle.x - r, y: handle.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(colour.opacity(dimmed ? 0.4 : 1)))
            }
        }
    }

    // MARK: - The cut

    /// The band, as its two bounding rectangles.
    ///
    /// Both edges rather than one, because a single plane says where the cut is
    /// but not how thick it is - and thickness is the thing the control sets.
    private func drawSection(renderer: Renderer, size: CGSize,
                             in context: inout GraphicsContext) {
        let quads = renderer.sectionQuads(viewSize: size)
        guard !quads.isEmpty else { return }

        for quad in quads {
            var path = Path()
            path.addLines(quad)
            path.closeSubpath()
            context.stroke(path, with: .color(Theme.ink500.opacity(0.5)),
                           lineWidth: Theme.hairline)
        }

        // Join the two rectangles at their corners, so the band reads as one
        // solid slice rather than two unrelated outlines.
        if quads.count == 2 {
            var risers = Path()
            for corner in 0..<4 {
                risers.move(to: quads[0][corner])
                risers.addLine(to: quads[1][corner])
            }
            context.stroke(risers, with: .color(Theme.ink300.opacity(0.45)),
                           lineWidth: Theme.hairline)
        }
    }
}

struct ScaleBarView: View {
    /// World-space height of the view at the camera's focal distance.
    let visibleWorldHeight: Double

    /// Size of the canvas, in points. Must be the canvas, not this view's own
    /// frame: `visibleWorldHeight` describes the whole viewport.
    let canvasSize: CGSize

    /// A ratio is only meaningful without convergence.
    let isOrthographic: Bool

    /// Names the length. Unstated units make a scale bar decorative.
    let unit: LinearUnit

    var body: some View {
        let worldPerPoint = visibleWorldHeight / Double(max(canvasSize.height, 1))
        let bar = Self.niceLength(targetPoints: Double(canvasSize.width) * 0.15,
                                  worldPerPoint: worldPerPoint)

        return VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            if bar.points.isFinite, bar.points > 12, bar.points < Double(canvasSize.width) {
                // A graduated line, not a divided block.
                //
                // The alternating filled bar is the cartographic convention;
                // the drafting convention is a rule with graduations, which is
                // also the only one that obeys this interface's own vocabulary
                // - hairline strokes, the point as the sole fill, no boxes.
                // Tick height carries the hierarchy: ends, then the half, then
                // the quarters.
                Graduations()
                    .stroke(Theme.ink500, lineWidth: Theme.hairline)
                    .frame(width: bar.points, height: 7)

                Text("\(Self.format(bar.world)) \(unit.kind.abbreviation)")
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink500)
            }
        }
        .frame(height: 24, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    /// Snap to a 1-2-5 sequence so the label is always a round number.
    static func niceLength(targetPoints: Double, worldPerPoint: Double) -> (world: Double, points: Double) {
        guard worldPerPoint.isFinite, worldPerPoint > 0, targetPoints > 0 else { return (0, 0) }
        let raw = targetPoints * worldPerPoint
        guard raw.isFinite, raw > 0 else { return (0, 0) }

        let exponent = floor(log10(raw))
        let base = raw / pow(10, exponent)
        let niceBase: Double = base < 1.5 ? 1 : (base < 3.5 ? 2 : (base < 7.5 ? 5 : 10))
        let world = niceBase * pow(10, exponent)
        return (world, world / worldPerPoint)
    }

    static func format(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.0f", value) }
        return String(format: "%g", value)
    }
}

/// The rule and its graduations. Zero is not labelled: a scale bar begins at
/// zero by definition, and the mark would say nothing the reader does not know.
private struct Graduations: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let base = r.maxY
        p.move(to: CGPoint(x: r.minX, y: base))
        p.addLine(to: CGPoint(x: r.maxX, y: base))

        // ends tallest, the half next, the quarters shortest
        let ticks: [(CGFloat, CGFloat)] = [(0, 7), (0.25, 3), (0.5, 5), (0.75, 3), (1, 7)]
        for (t, h) in ticks {
            let x = r.minX + r.width * t
            p.move(to: CGPoint(x: x, y: base))
            p.addLine(to: CGPoint(x: x, y: base - h))
        }
        return p
    }
}

// MARK: - Selection Rectangle View

/// A hairline, not a filled box: the marquee is a mark on the paper.
struct SelectionRectangleView: View {
    let rect: CGRect

    var body: some View {
        GeometryReader { _ in
            Rectangle()
                .stroke(Theme.seal, lineWidth: Theme.hairline)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView().environmentObject(ViewModel())
}
