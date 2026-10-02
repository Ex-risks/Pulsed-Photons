import SwiftUI
import MetalKit
import AppKit

/// Main view model for the app
@MainActor
final class ViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var visualizationMode: VisualizationMode = .solid {
        didSet { renderer?.visualizationMode = visualizationMode }
    }

    var effectiveDarkGround: Bool { isDarkMode }

    /// Which channels the loaded file actually carries.
    @Published private(set) var hasColors = false
    @Published private(set) var hasIntensity = false

    @Published var pointSize: Float = 3.0 {
        didSet { renderer?.pointSize = pointSize }
    }

    /// Strength of the x-ray / silhouette overlay, over whichever channel is
    /// selected. Replaces the old opacity control, which only existed to expose
    /// those two readings when they were modes of their own.
    @Published var overlayStrength: Float = 0.0 {
        didSet { renderer?.overlayStrength = overlayStrength }
    }

    /// Thickness of the section band, in the file's own units.
    ///
    /// Zero leaves the cloud whole. The band is centred on the camera's pivot,
    /// so panning sets the height of the cut and this sets how thick it is -
    /// one control where two would otherwise be needed.
    @Published var sectionThickness: Float = 0.0 {
        didSet {
            renderer?.sectionThickness = sectionThickness
            refreshOverlayClock()
        }
    }

    /// Whether the ground grid is drawn.
    @Published var showGrid: Bool = false {
        didSet { renderer?.showGrid = showGrid }
    }

    /// Spacing of the grid, in the file's own units.
    ///
    /// Derived rather than stored: a pure function of how much world the
    /// viewport shows, so it cannot fall out of step with what is drawn.
    var gridSpacing: Float {
        GridRenderer.niceSpacing(targetWorld: Float(visibleWorldHeight) / 10)
    }

    // MARK: - Turning the model

    /// Whether the rotation handles are shown.
    ///
    /// Rotation used to be three typed angles. Handles replace them because the
    /// question being asked is never "what is 23 degrees" - it is "line this
    /// wall up with the grid", which the eye answers and a number cannot.
    @Published var isTurning: Bool = false {
        didSet { refreshOverlayClock() }
    }

    private var boundsTask: Task<Void, Never>?

    /// Turn the model about a world axis.
    ///
    /// Composed on the left of the existing orientation, so the axis stays the
    /// world's rather than the model's - dragging the vertical ring turns the
    /// building about vertical no matter how it is already tilted, which is the
    /// only behaviour that matches what the handle looks like it will do.
    func turnModel(about axis: SIMD3<Float>, by radians: Float) {
        guard let renderer = renderer, radians.isFinite, radians != 0 else { return }
        renderer.camera.applyModelRotation(simd_quatf(angle: radians, axis: simd_normalize(axis)))
        scheduleBoundsRefresh()
    }

    /// Return the model to the orientation it was loaded in.
    func resetTurn() {
        renderer?.setModelOrientation(simd_quatf(angle: 0, axis: [0, 0, 1]))
        scheduleBoundsRefresh()
    }

    /// Which handle is being dragged, so it can be drawn as the live one.
    @Published private(set) var activeTurnAxis: Int? = nil

    /// How near a ring a press has to land, in points.
    private static let grabTolerance: CGFloat = 9

    private var turnStartAngle: Float = 0
    private var turnSign: Float = 1
    private var turnAccumulated: Float = 0

    /// Try to grab a handle. Returns false if the press was not on one, which
    /// lets the drag fall through to orbiting.
    func beginTurn(at point: CGPoint, viewSize: CGSize) -> Bool {
        guard isTurning, let renderer = renderer, pointCount > 0 else { return false }

        // Ignore a press nowhere near the gizmo outright, so the rest of the
        // sheet keeps orbiting without three ring walks per press.
        let centre = Renderer.gizmoCentre(viewSize: viewSize)
        guard hypot(point.x - centre.x, point.y - centre.y)
                < Renderer.gizmoRadius + Self.grabTolerance else { return false }

        var best: Int? = nil
        var bestDistance = Self.grabTolerance

        for axis in 0..<3 {
            for (p, _) in renderer.gizmoRing(axis: axis, viewSize: viewSize) {
                let d = hypot(p.x - point.x, p.y - point.y)
                if d < bestDistance { bestDistance = d; best = axis }
            }
        }

        guard let axis = best else { return false }

        activeTurnAxis = axis
        turnSign = renderer.gizmoScreenSign(axis: axis, viewSize: viewSize)
        turnStartAngle = Float(atan2(point.y - centre.y, point.x - centre.x))
        turnAccumulated = 0
        return true
    }

    /// Follow the pointer around the handle.
    ///
    /// The turn is the change in screen angle about the model's centre, which
    /// is what makes the handle feel attached to the pointer rather than to
    /// some horizontal drag distance.
    func continueTurn(to point: CGPoint, viewSize: CGSize, snapping: Bool) {
        guard let axis = activeTurnAxis, let renderer = renderer else { return }
        let centre = Renderer.gizmoCentre(viewSize: viewSize)

        let angle = Float(atan2(point.y - centre.y, point.x - centre.x))
        var delta = angle - turnStartAngle
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        turnStartAngle = angle

        var target = turnAccumulated + delta * turnSign
        if snapping {
            let step = Float.pi / 12          // 15 degrees
            target = (target / step).rounded() * step
        }

        let applied = target - turnAccumulated
        turnAccumulated = target
        guard applied != 0 else { return }
        renderer.camera.applyModelRotation(
            simd_quatf(angle: applied, axis: Renderer.worldAxis(axis)))
    }

    func endTurn() {
        guard activeTurnAxis != nil else { return }
        activeTurnAxis = nil
        scheduleBoundsRefresh()
    }

    @Published var isDarkMode: Bool = false {
        didSet {
            renderer?.isDarkMode = effectiveDarkGround
            renderer?.pointColor = Theme.pointColor(isDarkMode: effectiveDarkGround)
        }
    }

    /// Which world axis is up. Set from the file format on load, and
    /// overridable - PLY in particular carries no convention, so photogrammetry
    /// output is often Y-up while scanner and survey output is Z-up.
    @Published var upAxis: UpAxis = .z {
        didSet { renderer?.upAxis = upAxis }
    }

    @Published var exportScale: CGFloat = 2.0 // 1x, 2x, 3x, 4x resolution

    /// Points to render into the image. Defaults to everything loaded - a still
    /// has no frame budget - but it is stated rather than assumed, because a
    /// draft at 2M is a reasonable thing to want.
    @Published var exportPointCount: Int = 0

    // Subsampling
    @Published var subsampleLevel: Float = 1.0 {
        didSet { if !suppressResample { scheduleResample() } }
    }
    private var resampleTask: Task<Void, Never>?
    private var suppressResample = false

    /// Mirror a level the renderer has already applied, without asking it to
    /// resample all over again.
    private func setSubsampleLevelSilently(_ level: Float) {
        resampleTask?.cancel()
        suppressResample = true
        subsampleLevel = level
        suppressResample = false
    }

    /// Debounce the slider, then sample off the main actor.
    ///
    /// Sampling used to run synchronously in `didSet`, so every tick of a drag
    /// blocked the main thread - measured at 274ms for 5M points and 381ms for
    /// 3M with the old voxel sampler.
    private func scheduleResample() {
        resampleTask?.cancel()
        guard let renderer = renderer else { return }

        let level = subsampleLevel
        resampleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self = self else { return }

            let source = renderer.displaySourceVertices   // COW, no copy
            let target = renderer.plannedCount(for: level)

            let sampled = await Task.detached(priority: .userInitiated) {
                Renderer.stratifiedSample(source, count: target)
            }.value

            guard !Task.isCancelled else { return }
            renderer.applyDisplayVertices(sampled, level: level)
            self.syncCounts()
        }
    }

    // Selection
    /// True while the pointer is driving the camera. Shows the pivot reticle
    /// and, later, selects the motion point budget.
    @Published var isInteracting: Bool = false {
        didSet { renderer?.isInteracting = isInteracting }
    }

    @Published var isSelectionMode: Bool = false
    @Published var hasSelection: Bool = false
    @Published var selectionRect: CGRect? = nil

    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Progress of the current long operation, 0...1, or nil when idle.
    /// Updates are throttled to whole percents at the source.
    @Published private(set) var progress: Double? = nil
    @Published private(set) var progressLabel: String? = nil
    @Published private(set) var progressDetail: String? = nil

    private func beginProgress(_ label: String) {
        progressLabel = label
        progressDetail = nil
        progress = 0
    }

    private func endProgress() {
        progress = nil
        progressLabel = nil
        progressDetail = nil
    }

    /// Point counts are mirrored into published state so SwiftUI actually
    /// re-renders when they change. As computed properties reading through to
    /// the renderer they only updated when some *other* published value
    /// happened to change.
    @Published private(set) var pointCount: Int = 0
    @Published private(set) var originalPointCount: Int = 0
    @Published private(set) var selectedCount: Int = 0

    /// Bounding size of the loaded cloud, in the file's own units.
    @Published private(set) var extent: SIMD3<Float> = .zero

    /// Height of the cloud along the up axis - the span a section cut can move
    /// through, and so the upper bound of its thickness.
    var verticalExtent: Float {
        upAxis == .y ? extent.y : extent.z
    }

    /// The sheet names its subject in the top margin.
    @Published private(set) var fileName: String? = nil

    /// What the file turned out to contain, set as a caption beneath its name.
    @Published private(set) var datasetSummary: [String] = []

    /// The unit every stated distance is counted in - the scale bar, the grid,
    /// and every measurement.
    ///
    /// Read from the file's coordinate system when it has one. Most LAS does
    /// not, so this is usually the assumed default until the user says
    /// otherwise, and it reads faint until someone does.
    @Published private(set) var units: LinearUnit = .assumedMetre

    /// Which canonical view is framed, if any, and whether the projection is
    /// orthographic - the scale bar only states a ratio without convergence.
    @Published private(set) var standardView: Camera.StandardView? = nil
    @Published private(set) var isOrthographic: Bool = false

    /// True once points have been deleted - i.e. there is something to restore.
    @Published private(set) var hasEdits: Bool = false

    /// World-space height of the view at the camera's focal distance. The scale
    /// bar divides this by its own height in points to get world-per-point,
    /// which keeps it independent of backing scale.
    @Published private(set) var visibleWorldHeight: Double = 0

    // MARK: - Renderer

    var renderer: Renderer?
    weak var metalView: MTKView?

    // MARK: - Setup

    /// Build the renderer. Safe to call before the view has been laid out:
    /// `draw(in:)` skips frames until the drawable has a non-zero size.
    func setupRenderer(metalView: MTKView) {
        guard renderer == nil else { return }
        self.metalView = metalView

        guard let newRenderer = Renderer(metalView: metalView) else {
            errorMessage = "Failed to create Metal renderer"
            return
        }

        self.renderer = newRenderer

        // Do NOT assign drawableSize. Doing so sets autoResizeDrawable = false,
        // which stops the drawable tracking window resizes, and bounds.size is
        // in points - so on a Retina display it also halved the resolution.
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false

        // Push current UI state into the freshly created renderer.
        newRenderer.visualizationMode = visualizationMode
        newRenderer.pointSize = pointSize
        newRenderer.overlayStrength = overlayStrength
        newRenderer.showGrid = showGrid
        newRenderer.sectionThickness = sectionThickness
        newRenderer.isDarkMode = effectiveDarkGround
        newRenderer.pointColor = Theme.pointColor(isDarkMode: effectiveDarkGround)
        newRenderer.upAxis = upAxis
        refreshOverlayClock()

        // Fired from draw(in:) on the main thread, only when the value has
        // moved materially. Hopping through a Task keeps this free of any
        // assumption about the caller's isolation.
        newRenderer.onBufferAllocationFailure = { [weak self] count in
            Task { @MainActor in
                self?.errorMessage = "Not enough memory for \(ViewModel.compactCount(count)) points - reduce the point budget"
            }
        }

        newRenderer.onVisibleWorldHeightChange = { [weak self] value in
            Task { @MainActor in self?.visibleWorldHeight = value }
        }

        visibleWorldHeight = newRenderer.visibleWorldHeight
        ppLog("ViewModel: renderer ready")
    }

    /// What the file contained, stated plainly.
    ///
    /// Everything here is measured rather than assumed - channels are reported
    /// only if the parser actually found them, and the origin is the true world
    /// position the local coordinates are relative to.
    static func summarise(_ cloud: PointCloud, format: String) -> [String] {
        // Channels are shown by emphasis in the mode selector, extent and
        // origin were removed as noise, and the count already sits in the
        // points control - which leaves the one thing nothing else says.
        return ["\(cloud.pointCount.formatted()) points · \(format)"]
    }

    /// State the unit the coordinates are counted in.
    ///
    /// Marked as declared, because the user asserting a unit is a statement in
    /// the same way the file's coordinate system is. Only the untouched
    /// default stays faint.
    func setUnit(_ kind: LinearUnit.Kind) {
        units = LinearUnit(kind: kind, isDeclared: true)
    }

    /// Step to the next unit. The set is small enough that cycling beats a menu.
    func cycleUnit() {
        let all = LinearUnit.Kind.allCases
        let next = all[((all.firstIndex(of: units.kind) ?? 0) + 1) % all.count]
        setUnit(next)
    }

    /// Recompute the model's axis-aligned bounds for the current orientation,
    /// once the numerals have settled.
    ///
    /// One pass over the working set - tens of milliseconds on a large cloud -
    /// so running it per scrub tick would make the control stutter. Bounds feed
    /// the height ramp, the depth range and the grid, all of which tolerate
    /// being a beat behind mid-drag.
    private func scheduleBoundsRefresh() {
        guard let renderer = renderer, pointCount > 0 else { return }
        boundsTask?.cancel()
        boundsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self = self else { return }

            let working = renderer.displaySourceVertices
            let orientation = renderer.camera.targetModelOrientation
            let b = await Task.detached(priority: .userInitiated) {
                Renderer.bounds(of: working, rotatedBy: orientation)
            }.value

            guard !Task.isCancelled else { return }
            renderer.adoptBounds(min: b.min, max: b.max)
            self.syncCounts()
        }
    }

    /// Publish the model's orientation into the TURN numerals, without letting
    /// that write loop back into the orientation it came from.
    /// Ticks once per drawn frame, observed only by the model overlay.
    ///
    /// The handles and the section plane are drawn in SwiftUI but live in the
    /// scene, so they have to follow a camera SwiftUI cannot see. Keeping the
    /// tick on its own object stops a 60Hz signal re-evaluating the interface.
    let cameraClock = CameraClock()

    /// Drive that clock only while there is something in the scene to draw.
    func refreshOverlayClock() {
        renderer?.onFrameDrawn = { [weak self] in
            guard let self = self else { return }
            guard self.isTurning || self.sectionThickness > 0 else { return }
            self.cameraClock.generation &+= 1
        }
    }

    /// Publish current renderer state. Used by offscreen design rendering,
    /// which loads a cloud directly into the renderer.
    func forcePublishForPreview() { syncCounts() }
    func setFileNameForPreview(_ n: String) { fileName = n }
    func setSummaryForPreview(_ l: [String]) { datasetSummary = l }
    func setChannelsForPreview(colors: Bool, intensity: Bool) { hasColors = colors; hasIntensity = intensity }

    /// Mirror renderer state into published properties.
    private func syncCounts() {
        pointCount = renderer?.totalPointCount() ?? 0
        originalPointCount = renderer?.originalPointCount() ?? 0
        selectedCount = renderer?.selectionCount ?? 0
        hasSelection = selectedCount > 0
        extent = renderer?.boundsSize ?? .zero
        if let r = renderer {
            hasEdits = r.workingPointCount() != r.originalPointCount()
        }
        if let r = renderer { visibleWorldHeight = r.visibleWorldHeight }
    }

    // MARK: - Camera Controls

    func resetCamera() {
        renderer?.resetCamera()
    }

    func fitToBounds() {
        renderer?.fitCameraToBounds()
    }

    /// Snap to a canonical orientation and re-frame. Plan and elevation views
    /// switch to orthographic; orbiting freely returns to perspective.
    func setStandardView(_ view: Camera.StandardView) {
        guard let renderer = renderer else { return }
        renderer.camera.setStandardView(view)
        renderer.fitCameraToBounds(preserveOrientation: true)
        standardView = view
        isOrthographic = renderer.camera.isOrthographic
    }

    /// Screen position of the orbit pivot, for the targeting reticle.
    func pivotScreenPosition(in size: CGSize) -> CGPoint? {
        guard let renderer = renderer, size.width > 0, size.height > 0 else { return nil }
        return renderer.projectToScreen(renderer.camera.target, viewSize: size)
    }

    // MARK: - Selection

    private var editTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    func selectPoints(in rect: CGRect) {
        guard let renderer = renderer, let metalView = metalView else { return }
        let viewSize = metalView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        // Capture the transform now, on the main actor, so the selection is
        // tested against exactly the frame the user drew the marquee over.
        let mvp = renderer.selectionTransform(aspectRatio: Float(viewSize.width / viewSize.height))
        let source = renderer.displaySourceVertices   // COW, no copy

        editTask?.cancel()
        editTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Renderer.selectionMask(in: rect, vertices: source, transform: mvp, viewSize: viewSize)
            }.value

            guard !Task.isCancelled, let self = self else { return }
            renderer.applySelection(mask: result.mask, count: result.count)
            self.syncCounts()
        }
    }

    func deleteSelectedPoints() {
        guard let renderer = renderer, renderer.selectionCount > 0 else { return }

        let source = renderer.displaySourceVertices
        let mask = renderer.selection

        editTask?.cancel()
        editTask = Task { @MainActor [weak self] in
            let edited = await Task.detached(priority: .userInitiated) { () -> ([PointVertex], SIMD3<Float>, SIMD3<Float>) in
                let kept = Renderer.removingMasked(mask, from: source)
                let b = Renderer.bounds(of: kept)
                return (kept, b.min, b.max)
            }.value

            guard !Task.isCancelled, let self = self else { return }
            renderer.applyEdit(vertices: edited.0, min: edited.1, max: edited.2)
            self.syncCounts()
        }
    }

    /// Level a tilted scan: find the ground plane and rotate it flat.
    ///
    /// The rotation is carried by the model matrix rather than written into the
    /// points, so this costs one sampled plane fit plus one read-only bounds
    /// pass - no gigabyte-scale copying, and it stays responsive on any cloud.
    func levelToGround() {
        guard let renderer = renderer, pointCount > 0 else { return }

        let working = renderer.displaySourceVertices
        let up = renderer.upAxis.vector
        let existing = renderer.camera.modelOrientation
        let e = renderer.boundsSize
        let extent = max(e.x, max(e.y, e.z))
        guard extent > 0 else { return }

        beginProgress("levelling")
        let onProgress: @Sendable (Double) -> Void = { [weak self] f in
            Task { @MainActor in self?.progress = f }
        }

        editTask?.cancel()
        editTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (simd_quatf, SIMD3<Float>, SIMD3<Float>)? in
                onProgress(0.1)
                // Fit in the space the points already sit in, then compose with
                // whatever orientation is already applied.
                let localUp = simd_normalize(existing.inverse.act(up))
                guard let rotation = Renderer.levellingRotation(for: working, up: localUp, extent: extent) else {
                    return nil
                }
                onProgress(0.6)
                let combined = simd_normalize(rotation * existing)
                let b = Renderer.bounds(of: working, rotatedBy: combined)
                onProgress(1.0)
                return (rotation, b.min, b.max)
            }.value

            guard let self = self else { return }
            defer { self.endProgress() }
            guard !Task.isCancelled else { return }

            guard let result = result else {
                self.errorMessage = "No ground plane found - the scan may already be level"
                return
            }
            renderer.applyLevelling(rotation: result.0, min: result.1, max: result.2)
            self.syncCounts()
        }
    }

    func clearSelection() {
        renderer?.clearSelection()
        syncCounts()
    }

    func restoreOriginal() {
        guard let renderer = renderer else { return }
        renderer.restoreOriginal()
        setSubsampleLevelSilently(renderer.currentLevel())
        syncCounts()
    }

    // MARK: - File Loading

    /// Open a file, either replacing the scene or adding to it.
    func loadFile(url: URL, adding: Bool = false) async {
        guard let renderer = renderer else {
            errorMessage = "Renderer not ready. Please try again."
            return
        }

        isLoading = true
        errorMessage = nil
        beginProgress("reading")
        defer {
            isLoading = false
            endProgress()
        }

        // Parsers run off the main actor and report whole percents; hop back
        // here to publish. Throttling happens at the source, so this is at most
        // 100 hops for an entire file.
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }

        // Start accessing security-scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        let ext = url.pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "File not found"
            return
        }

        do {
            // Sandboxed drops occasionally hand back a URL we cannot open
            // directly; fall back to a copy inside our own container.
            var parseURL = url
            if (try? FileHandle(forReadingFrom: url)) == nil {
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil {
                    parseURL = tempURL
                }
            }

            let pointCloud: PointCloud
            switch ext {
            case "ply":
                pointCloud = try await PLYParser.parse(url: parseURL, progress: onProgress)
            case "xyz", "txt":
                pointCloud = try await XYZParser.parse(url: parseURL, progress: onProgress)
            case "las":
                pointCloud = try await LASParser.parse(url: parseURL, progress: onProgress)
            default:
                throw ParserError.unsupportedFormat(ext)
            }

            if adding && pointCount > 0 {
                renderer.appendPointCloud(pointCloud)
                loadedFiles.append(pointCloud.fileName)
                // Channels are the intersection of what is present: a mode is
                // only honestly available if every loaded file can fill it.
                hasColors = hasColors && pointCloud.hasColors
                hasIntensity = hasIntensity && pointCloud.hasIntensity
            } else {
                renderer.loadPointCloud(pointCloud)
                loadedFiles = [pointCloud.fileName]
                hasColors = pointCloud.hasColors
                hasIntensity = pointCloud.hasIntensity
                units = pointCloud.units
            }
            fileName = Self.sceneName(loadedFiles)
            datasetSummary = Self.summarise(pointCloud, format: ext)

            // Pick a mode the data can actually support, and route it through
            // the published property so the toolbar reflects reality.
            if hasColors {
                visualizationMode = .rgb
            } else if hasIntensity {
                visualizationMode = .intensity
            } else {
                visualizationMode = .solid
            }

            setSubsampleLevelSilently(renderer.currentLevel())

            // MTKView manages drawableSize itself; assigning it here would turn
            // off autoResizeDrawable and drop to point-resolution on Retina.
            renderer.fitCameraToBounds()
            syncCounts()

            ppLog("Loaded \(pointCloud.pointCount) points from \(url.lastPathComponent); displaying \(pointCount)")

        } catch {
            errorMessage = "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
            ppLog("ERROR: \(error)")
        }
    }

    /// Names of every file in the scene, in the order they were opened.
    @Published private(set) var loadedFiles: [String] = []

    /// What the title bar of the sheet calls the scene.
    static func sceneName(_ files: [String]) -> String? {
        guard let first = files.first else { return nil }
        return files.count == 1 ? first : "\(first) + \(files.count - 1)"
    }

    /// Empty the scene.
    func closeCloud() {
        editTask?.cancel()
        resampleTask?.cancel()
        boundsTask?.cancel()
        renderer?.unload()

        loadedFiles = []
        fileName = nil
        datasetSummary = []
        hasColors = false
        hasIntensity = false
        units = .assumedMetre
        isTurning = false
        isSelectionMode = false
        showGrid = false
        sectionThickness = 0
        overlayStrength = 0
        errorMessage = nil
        setSubsampleLevelSilently(1.0)
        syncCounts()
    }

    // MARK: - Export

    /// Whether the export sheet is showing. A panel in the application's own
    /// hand rather than a system submenu, so the one place formats are chosen
    /// looks like the rest of the interface.
    @Published var isExporting = false

    /// Whether the about sheet is showing.
    @Published var isShowingAbout = false

    /// Write the scene to a point cloud file.
    ///
    /// Writes the *working* set, not the originally loaded one: what leaves
    /// should be what is on the sheet, deletions included.
    func exportCloud(format: PointCloudFormat) {
        guard let renderer = renderer, pointCount > 0 else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            ((loadedFiles.first as NSString?)?.deletingPathExtension ?? "cloud")
            + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.title = "Export \(format.name)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let vertices = renderer.displaySourceVertices     // COW, no copy
        let cloud = PointCloud(vertices: vertices,
                               minBounds: renderer.boundsMin,
                               maxBounds: renderer.boundsMax,
                               hasColors: hasColors,
                               hasIntensity: hasIntensity,
                               worldOrigin: renderer.worldOrigin,
                               fileName: url.lastPathComponent)

        beginProgress("writing \(format.name)")
        let onProgress: @Sendable (Double) -> Void = { [weak self] f in
            Task { @MainActor in self?.progress = f }
        }

        Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try PointCloudWriter.write(cloud, to: url, format: format,
                                               progress: onProgress)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self = self else { return }
            self.endProgress()
            if let failure = failure {
                self.errorMessage = "Could not write \(url.lastPathComponent): \(failure)"
            }
        }
    }

    func exportImage() {
        guard let renderer = renderer, let metalView = metalView else {
            errorMessage = "No renderer available for export"
            return
        }

        let total = renderer.workingPointCount()
        if exportPointCount == 0 || exportPointCount > total { exportPointCount = total }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = (fileName.map {
            ($0 as NSString).deletingPathExtension
        } ?? "pulsed_photons") + ".png"

        // The choices that change the artefact live with the act of writing it,
        // not somewhere in the interface to be remembered beforehand.
        let options = ExportOptions(viewModel: self,
                                    total: total,
                                    drawableSize: metalView.drawableSize)
        let host = NSHostingView(rootView: options)
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 74)
        panel.accessoryView = host

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.performExport(to: url, renderer: renderer, metalView: metalView)
            }
        }
    }

    /// Render every point in the cloud to an image file.
    ///
    /// The interactive view is capped at 3M points because that is a frame-time
    /// budget. A still has no such budget, so this streams the whole cloud
    /// through the GPU in batches - a 4x export of an 80M-point scan contains
    /// all 80M, not the 3M you were navigating with.
    private func performExport(to url: URL, renderer: Renderer, metalView: MTKView) {
        // Scale from the *drawable*, not from `bounds`. Bounds are in points,
        // so on a Retina display that made "1x" half the on-screen resolution.
        let base = metalView.drawableSize
        var width = Int(base.width * exportScale)
        var height = Int(base.height * exportScale)

        guard width > 0, height > 0 else {
            errorMessage = "Invalid view size for export"
            return
        }

        // Clamp to what the GPU can actually allocate, preserving aspect. A
        // maximised window at 4x can exceed the 16384 limit, and Metal aborts
        // on that rather than refusing it.
        let longest = max(width, height)
        if longest > Renderer.maxTextureSize {
            let k = Double(Renderer.maxTextureSize) / Double(longest)
            width = max(1, Int(Double(width) * k))
            height = max(1, Int(Double(height) * k))
            ppLog("Export clamped to \(width)x\(height) (GPU limit)")
        }

        // Splats stay pixel-constant: a higher-resolution export resolves finer
        // structure rather than magnifying the same marks.
        var job = renderer.makeExportJob(width: width, height: height)
        // Honour the requested count by trimming the job's own copy: the
        // display buffer is shuffled, so a prefix is a uniform sample.
        let requested = max(1, min(exportPointCount, job.vertices.count))
        if requested < job.vertices.count {
            job = job.limited(to: requested)
        }
        let total = job.vertices.count
        let isDark = renderer.isDarkMode
        let markScale = exportScale

        beginProgress("exporting")
        progressDetail = "\(Self.compactCount(total)) points  ·  \(width)×\(height)"

        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.progress = fraction }
        }

        exportTask?.cancel()
        exportTask = Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                Renderer.renderExport(job, progress: onProgress)
            }.value

            guard let self = self else { return }
            defer { self.endProgress() }
            guard !Task.isCancelled else { return }

            guard let cgImage = image else {
                self.errorMessage = "Export failed"
                return
            }
            await self.write(cgImage, to: url, isDarkMode: isDark, markScale: markScale)
        }
    }

    /// Encode and write. The heavy work happens off the main actor; only the
    /// error, if any, comes back here.
    private func write(_ cgImage: CGImage, to url: URL,
                       isDarkMode: Bool, markScale: CGFloat) async {
        let markColor = Theme.exportMarkColor(isDarkMode: isDarkMode)
        let failure = await Task.detached(priority: .userInitiated) {
            Renderer.writeImage(cgImage, to: url,
                                signature: "pulsed photons",
                                markColor: markColor,
                                markScale: markScale)
        }.value

        if let failure = failure {
            errorMessage = failure
        } else {
            ppLog("Exported \(cgImage.width)x\(cgImage.height) to \(url.path)")
        }
    }

    static func compactCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Parser Error

/// A 60Hz tick, kept apart from the view model on purpose.
///
/// The dimension overlay has to follow the camera, which SwiftUI has no way to
/// observe. Publishing that from the view model would re-evaluate the whole
/// interface every frame; on its own object, only the overlay listens.
final class CameraClock: ObservableObject {
    @Published var generation: Int = 0
}

enum ParserError: LocalizedError {
    case unsupportedFormat(String)
    case invalidData
    case fileNotFound
    case readError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        case .invalidData:
            return "Invalid or corrupted file data"
        case .fileNotFound:
            return "File not found"
        case .readError(let message):
            return "Read error: \(message)"
        }
    }
}
