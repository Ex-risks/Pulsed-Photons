import SwiftUI
import MetalKit

/// NSViewRepresentable wrapper for MTKView with gesture support
struct MetalView: NSViewRepresentable {
    @ObservedObject var viewModel: ViewModel

    func makeNSView(context: Context) -> SelectableMetalView {
        let mtkView = SelectableMetalView()

        // Start paused; setupRenderer unpauses once the device is attached.
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60

        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = true

        // Scroll zooms, on every device - the original mapping. A trackpad
        // reports finer deltas than a wheel, so only the scaling differs.
        mtkView.onScroll = { [weak viewModel] event in
            guard let camera = viewModel?.renderer?.camera else { return }
            let scale: Float = event.hasPreciseScrollingDeltas ? 0.34 : 0.9
            camera.zoom(delta: Float(event.scrollingDeltaY) * scale)
        }

        setupGestures(mtkView, context: context)

        // Build the renderer here, not in updateNSView.
        //
        // updateNSView previously deferred this until bounds were non-zero, but
        // SwiftUI calls it once at creation - before layout - and then only when
        // observed state changes. Nothing re-triggered it, so the renderer was
        // never created and every drop reported "Renderer not ready". It used to
        // work only because a deferred `showDropPrompt` write happened to
        // publish a change shortly after launch.
        viewModel.setupRenderer(metalView: mtkView)

        return mtkView
    }

    func updateNSView(_ nsView: SelectableMetalView, context: Context) {
        nsView.clearColor = Renderer.backgroundClearColor(isDarkMode: viewModel.effectiveDarkGround)
    }

    private func setupGestures(_ view: NSView, context: Context) {
        // Pan for orbit (left mouse drag)
        let panGesture = NSPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handlePan(_:)))
        panGesture.buttonMask = 0x1 // Left mouse button
        view.addGestureRecognizer(panGesture)

        // Magnify for zoom (pinch)
        let magnifyGesture = NSMagnificationGestureRecognizer(target: context.coordinator,
                                                               action: #selector(Coordinator.handleMagnify(_:)))
        view.addGestureRecognizer(magnifyGesture)

        // Double-click to fit
        let doubleClickGesture = NSClickGestureRecognizer(target: context.coordinator,
                                                           action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClickGesture.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClickGesture)

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, NSGestureRecognizerDelegate {


        let viewModel: ViewModel
        private var selectionStart: CGPoint? = nil

        /// Whether this drag started on a rotation handle. A drag that began
        /// off one must orbit for its whole life, not snap to a handle the
        /// pointer happens to cross later.
        private var grabbedHandle = false

        init(viewModel: ViewModel) {
            self.viewModel = viewModel
        }

        /// MTKView is not flipped, so AppKit reports gesture locations with a
        /// bottom-left origin. Both consumers of the selection rect - the
        /// SwiftUI overlay and the NDC maths in `selectionMask(in:)` - work in
        /// top-left coordinates, so convert once, here.
        private func topLeftLocation(of gesture: NSGestureRecognizer) -> CGPoint {
            guard let view = gesture.view else { return gesture.location(in: nil) }
            let p = gesture.location(in: view)
            return view.isFlipped ? p : CGPoint(x: p.x, y: view.bounds.height - p.y)
        }

        /// The cursor names the gesture before it happens, so the modifier
        /// keys stop being something you have to remember.
        @MainActor
        private func updateCursor(selecting: Bool, command: Bool, option: Bool, shift: Bool) {
            let cursor: NSCursor
            if selecting        { cursor = .crosshair }
            else if command     { cursor = .openHand }      // rotate the model
            else if option      { cursor = .openHand }      // pan
            else if shift       { cursor = .resizeUpDown }  // zoom
            else                { cursor = .crosshair }     // orbit
            cursor.set()
        }

        @MainActor
        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)

            let event = NSApp.currentEvent
            let isOptionPressed = event?.modifierFlags.contains(.option) ?? false
            let isShiftPressed = event?.modifierFlags.contains(.shift) ?? false
            let isCommandPressed = event?.modifierFlags.contains(.command) ?? false
            let isControlPressed = event?.modifierFlags.contains(.control) ?? false

            updateCursor(selecting: isControlPressed || viewModel.isSelectionMode,
                         command: isCommandPressed, option: isOptionPressed, shift: isShiftPressed)

            switch gesture.state {
            case .began:  viewModel.isInteracting = true
            case .ended, .cancelled, .failed: viewModel.isInteracting = false
            default: break
            }

            // Turning the model, when a handle was actually grabbed.
            //
            // Routed through this gesture rather than a SwiftUI overlay on
            // purpose: an overlay armed for dragging would swallow every press,
            // and a press that misses a handle has to keep orbiting.
            if viewModel.isTurning {
                let location = topLeftLocation(of: gesture)
                let size = gesture.view?.bounds.size ?? .zero

                switch gesture.state {
                case .began:
                    grabbedHandle = viewModel.beginTurn(at: location, viewSize: size)
                case .changed where grabbedHandle:
                    viewModel.continueTurn(to: location, viewSize: size, snapping: isShiftPressed)
                case .ended, .cancelled, .failed:
                    if grabbedHandle { viewModel.endTurn() }
                    grabbedHandle = false
                default:
                    break
                }

                if grabbedHandle {
                    gesture.setTranslation(.zero, in: gesture.view)
                    return
                }
                // Missed the handle: fall through and orbit as usual.
            }

            // Control + drag = selection rectangle
            if isControlPressed || viewModel.isSelectionMode {
                let location = topLeftLocation(of: gesture)

                switch gesture.state {
                case .began:
                    selectionStart = location
                    viewModel.selectionRect = CGRect(origin: location, size: .zero)
                case .changed:
                    if let start = selectionStart {
                        viewModel.selectionRect = CGRect(
                            x: min(start.x, location.x),
                            y: min(start.y, location.y),
                            width: abs(location.x - start.x),
                            height: abs(location.y - start.y)
                        )
                    }
                case .ended, .cancelled:
                    if let rect = viewModel.selectionRect, rect.width > 5, rect.height > 5 {
                        viewModel.selectPoints(in: rect)
                    }
                    viewModel.selectionRect = nil
                    selectionStart = nil
                default:
                    break
                }
                return
            }

            if isCommandPressed {
                // Cmd + drag = rotate model
                viewModel.renderer?.camera.rotateModel(
                    deltaX: Float(translation.x),
                    deltaY: Float(-translation.y)
                )
            } else if isOptionPressed {
                // Option + drag = pan
                viewModel.renderer?.camera.pan(
                    deltaX: Float(translation.x),
                    deltaY: Float(-translation.y)
                )
            } else if isShiftPressed {
                // Shift + drag = zoom
                viewModel.renderer?.camera.zoom(delta: Float(translation.y) * 0.05)
            } else {
                // Normal drag = orbit camera
                viewModel.renderer?.camera.orbit(
                    deltaX: Float(translation.x),
                    deltaY: Float(translation.y)
                )
            }

            gesture.setTranslation(.zero, in: gesture.view)
        }

        @MainActor
        @objc func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
            switch gesture.state {
            case .began:  viewModel.isInteracting = true
            case .ended, .cancelled, .failed: viewModel.isInteracting = false
            default: break
            }
            let delta = Float(gesture.magnification)
            viewModel.renderer?.camera.zoom(delta: delta * 5.0)
            gesture.magnification = 0
        }

        @MainActor
        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            viewModel.fitToBounds()
        }

    }
}

/// Custom MTKView with scroll wheel support.
///
/// The selection rectangle is drawn by `SelectionRectangleView` in SwiftUI; an
/// earlier CAShapeLayer overlay here was driven from `draw(_ dirtyRect:)`,
/// which is not the render path for a Metal-backed view and never ran.
class SelectableMetalView: MTKView {
    var onScroll: ((NSEvent) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.isOpaque = true
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }


    override var acceptsFirstResponder: Bool { true }
}
