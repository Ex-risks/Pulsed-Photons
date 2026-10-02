# Pulsed Photons — Documentation

Architecture, rendering, formats, and how to extend them.

- [Shape of the app](#shape-of-the-app)
- [Data flow](#data-flow)
- [Coordinate precision](#coordinate-precision)
- [The rendering pipeline](#the-rendering-pipeline)
- [Progressive refinement](#progressive-refinement)
- [Sampling](#sampling)
- [Camera](#camera)
- [File formats](#file-formats)
- [Interface](#interface)
- [Testing](#testing)
- [Extending](#extending)
- [Shipping](#shipping)

---

## Shape of the app

```
PulsedPhotonsProApp        @main, menus, open panels
  └── ContentView          the sheet: canvas, overlays, sheets, bar
        ├── MetalView      NSViewRepresentable over MTKView; all pointer input
        ├── ModelOverlay   turn gizmo and section plane, drawn in SwiftUI
        ├── ToolbarView    every control
        └── ViewModel      @MainActor state, the only thing views observe
              └── Renderer MTKViewDelegate; owns the GPU and the point data
                    ├── Camera
                    └── GridRenderer
```

`ViewModel` is the boundary. Views never touch `Renderer`; `Renderer` never
publishes. Anything the interface needs to display is mirrored into a
`@Published` property, because computed properties reading through to the
renderer only updated when some *other* published value happened to change.

### Why the renderer holds the data

`Renderer` owns `originalVertices` and `workingVertices` rather than a document
type, because every operation on them — subsampling, selection, levelling,
bounds — needs to end in a GPU upload. Splitting ownership would mean the same
array crossing an actor boundary on every edit.

---

## Data flow

```
file ──► Parser ──► PointCloud ──► Renderer.loadPointCloud
                                        │
                                        ├─► originalVertices   (restore)
                                        ├─► workingVertices    (edits)
                                        └─► stratifiedSample ──► MTLBuffer
```

**`PointCloud`** is an immutable value type: interleaved vertices, bounds,
channel flags, world origin, units. Parsers build the interleaved array directly
rather than staging parallel attribute arrays — the difference between ~104 and
48 bytes per point at peak.

**`PointVertex`** is 48 bytes, declared in `ShaderTypes.h` so Swift and Metal
share one definition:

```c
typedef struct {
    simd_float3 position;
    simd_float4 color;
    float intensity;
    float scanAngle;
    float returnNumber;
    float timeStamp;
} PointVertex;
```

`scanAngle`, `returnNumber` and `timeStamp` are carried from LAS but not yet
consumed by any channel. They are kept for derived channels.

> Packing this to 16 bytes was tried and measured. It gave **no** speed benefit —
> the pipeline is primitive-rate bound, not bandwidth bound — so the only gain
> would have been memory, at the cost of every parser and shader. Not done.

---

## Coordinate precision

The single most important decision in the data path.

Georeferenced scans routinely carry UTM coordinates like `456789.123`. At that
magnitude a `Float` resolves to about **0.03 m** — worse than the scanner. So:

1. Parsers accumulate in `Double`.
2. The first kept point becomes a provisional **origin**.
3. Positions are stored as `Float` *relative to that origin*.
4. The cloud is then recentred on its bounding-box centre, and that shift folded
   into `worldOrigin`.

`PointCloud.worldOrigin` is the `Double` world position of the local origin. Add
it back to recover true coordinates. Every writer does exactly that.

At a 1 km site this gives about **0.1 mm** of precision — below the scanner's own
noise. The real floor is the file's quantisation: LAS typically stores at 0.001.

**Merging** several files re-bases each incoming cloud onto the first file's
origin, taking the difference in `Double` and only then narrowing. Two scans
kilometres apart still line up; two scans *hundreds* of kilometres apart will
start losing precision, which is the documented limit.

---

## The rendering pipeline

Points are drawn as `MTLPrimitiveType.point` — one primitive per point, no
instancing, no geometry stage.

### Round splats without MSAA

Metal rasterises points as squares. The fragment shader discards outside the
unit circle, then anti-aliases the rim **analytically**:

```metal
float edge = min(fwidth(d), 0.5);
float coverage = (edge > 0.0) ? (1.0 - smoothstep(1.0 - edge, 1.0, d)) : 1.0;
```

MSAA cannot do this. `discard_fragment` rejects a whole fragment rather than
individual samples, so a discard-masked circle stays hard-edged at any sample
count — measured: 2 distinct tones at both `sampleCount` 1 and 4, versus 16 from
analytic coverage at `sampleCount` 1. MSAA was therefore 4× the colour and depth
memory plus a resolve, for nothing.

### Three pipeline states

| State | Blend | Depth | Used for |
|---|---|---|---|
| `pipelineState` | source-over | tested, writing | `XRAY = off` |
| `pipelineStateAddInk` | additive | disabled | `XRAY > 0`, paper ground |
| `pipelineStateAddLight` | additive | disabled | `XRAY > 0`, sumi ground |

The x-ray reading is not a mode — it is the same draw with accumulation turned
on, so it composes with every data channel.

**Direction follows the ground.** On sumi a deposit *adds* light. On paper it
must *subtract* light, and subtracting the colour itself would yield its
complement — so the complement is what gets subtracted, which is how pigment
actually behaves:

```metal
float3 deposit = (uniforms.darkGround == 1) ? finalColor.rgb
                                            : (1.0 - finalColor.rgb);
```

### The section cut

Culled in the *vertex* shader, so a point outside the band costs nothing beyond
one comparison — no rasterisation, no fill:

```metal
if (uniforms.sectionHalf > 0.0 &&
    fabs(height - uniforms.sectionCentre) > uniforms.sectionHalf) {
    out.position = float4(0.0, 0.0, 2.0, 1.0);   // outside the clip volume
    out.pointSize = 0.0;
}
```

Pushing `z` past `w` is the defined way to drop a primitive without a geometry
stage. This is verified in `Checks/shaders.swift` rather than assumed — if Metal
did not clip point primitives this way, the cut would silently do nothing.

### Height along an arbitrary axis

Height mode projects onto the up axis rather than reading `position.z`, so the
ramp follows whichever axis the camera orbits about, and keeps working after the
model has been levelled or turned:

```swift
let axis = simd_normalize(camera.inverseModelRotation * camera.upAxis.vector)
```

The ramp itself is dark blue → slate → amber, deliberately *not* the usual
rainbow: that ramp is perceptually non-uniform, invents banding at the cyan and
yellow inflections, and is not colour-blind safe, so it misreports the data it
is meant to describe. This one is monotonic in luminance, so height still reads
correctly in greyscale.

### The grid

A separate pipeline drawing `MTLPrimitiveType.line`, with its own vertex format
(`GridVertex`) and uniforms. Drawn **first**, with depth writing on, so points in
front occlude it and it reads as a floor rather than a transparency.

It is **world-fixed** — deliberately not subject to the model matrix — because it
is the datum the model turns *against*. Spacing snaps to a 1-2-5 sequence chosen
so about ten cells span the viewport, and the mesh is rebuilt only when that
spacing changes, not as the camera moves.

---

## Progressive refinement

The frame loop, in `Renderer.draw(in:)`.

A still frame at 49M points costs ~220 ms in one draw. Instead the renderer keeps
a persistent colour and depth texture at drawable size and fills it a slice at a
time:

```
camera moving  ──►  target = 3M      drawn in one batch
camera still   ──►  target = all     drawn 2M per frame, accumulating
```

Each frame blits the accumulation onto the drawable, complete or not.

Three things make this safe rather than a trick:

1. **Any prefix is a uniform sample.** The display buffer is a shuffled
   stratified sample, so a half-finished frame looks like a *sparser* version of
   the finished one, never like half a model.
2. **A growing target does not reset.** Settling from motion continues from the
   3M already drawn, because those are exactly the prefix the larger target
   begins with.
3. **The clear is what makes the texture presentable.** A freshly allocated
   texture holds whatever was in that memory; the pass runs even with nothing to
   draw, and `accumCleared` stops it re-clearing every frame afterwards.

> Point 3 was a real bug: with no cloud loaded, nothing wrote to the texture and
> the blit showed uninitialised GPU memory — a magenta sheet.
> `Checks/refinement.swift` covers it.

### Redraw decision

`FrameState` captures everything that can change what a frame looks like, and is
compared against the last drawn frame. Dirty flags rely on every mutation site
remembering to set one; if the state feeding the draw call is unchanged, the
output is identical by construction.

`drawCount` is deliberately **not** in `FrameState` — it changes as refinement
proceeds, and would invalidate the very accumulation it was filling.

---

## Sampling

`Renderer.stratifiedSample(_:count:)` divides the array into `count` strata,
takes one point from each, then **shuffles** the result.

The shuffle is what makes progressive refinement work: it means any prefix of
the display buffer is itself a uniform sample of the whole cloud. Without it,
drawing the first 2M points would draw one contiguous region of the scan.

Resampling is debounced 120 ms and runs off the main actor. It used to run
synchronously in `didSet`, which blocked the main thread for 274 ms per tick of
the points slider.

---

## Camera

A goal-following arcball. Every input sets a *goal*; the camera follows it
through a critically damped spring:

```swift
private func smoothDamp(_ current: Float, _ target: Float,
                        _ velocity: inout Float, _ time: Float) -> Float
```

Decay alone only ever decelerates — motion begins at full speed the instant a
gesture starts, which reads as being shoved. Following a goal gives acceleration
at the start and settling at the end, with no overshoot.

Two details worth knowing:

- **`up` substitutes a secondary axis at the pole.** A plan view looks straight
  down the up axis, making the conventional up vector parallel to the view
  direction, and `lookAt` divides by a zero-length cross product. Clamping
  elevation just short of vertical was the old workaround and left every "top"
  view half a degree off square.
- **Projection switches to orthographic** for canonical views, because plans and
  elevations are only measurable without convergence. Orbiting freely returns to
  perspective.

Model rotation is carried by the **model matrix**, never written into the points.
It therefore costs nothing per frame, and no measurement changes because of it.

---

## File formats

### Reading

| Format | Notes |
|---|---|
| LAS 1.0–1.4 | point record formats 0–10; memory-mapped, single pass |
| PLY | ascii and binary, little and big endian; `float` and `double` positions |
| XYZ / TXT | whitespace-separated, optional RGB |

LAS parsing reads the coordinate system for units: GeoTIFF keys in VLR 34735
(`ProjLinearUnitsGeoKey`, 3076) for ≤1.3, or OGC WKT in VLR 2112 for 1.4 with
the WKT bit set.

> A foot-based projected CRS still defines its *ellipsoid* in metres, so a naive
> "search the WKT for metre" reader gets it backwards. Feet are tested first.

**Non-finite coordinates are skipped.** `Float("nan")` parses successfully, and
`NaN` reaching the bounds calculation poisons it and then traps on the `Int32`
narrowing inside subsampling. This was a real crash.

### Writing

`PointCloudWriter` streams in 262,144-vertex blocks — a 50M-point PLY is
hundreds of megabytes and should never be resident alongside the cloud it came
from.

| Format | Layout |
|---|---|
| PLY | binary little-endian, **`double`** position, `uchar` RGB |
| XYZ | text, three decimals, optional RGB |
| LAS | 1.2, point record format 2, 0.001 scale, origin as offset |

> PLY writes `double`, not `float`, and the reason is measurable. Written in
> world coordinates a georeferenced easting runs to seven digits, where a
> `float`'s spacing is about half a metre — round-tripping moved points by up to
> **249 mm**. This is exactly the precision the origin anchoring exists to
> protect, and writing `float` threw it away on the way out.

---

## Interface

### The design system

One type size (11 pt), two weights, one accent. Hierarchy is carried by **ink
value** — `ink900` / `ink700` / `ink500` / `ink300` — and by **interval**.

Colours are declared as (light, dark) pairs and resolved per appearance, so
views never branch on the current theme. Metal needs components rather than a
dynamic `Color`, so the few values the renderer needs are restated in
`Theme.gridColor` and `Theme.pointColor`.

The bar uses exactly one spacing ratio: items of an idea sit a fixed narrow gap
apart, and the gaps *between* ideas are elastic, sharing out whatever width is
left. Fixed inside, elastic between.

### `ScrubValue`

Every numeral in the bar. Drag to change, double-click to type, ⌥-click to reset.

The gesture precedence matters and was a bug:

```swift
TapGesture(count: 2)
    .exclusively(before: DragGesture(minimumDistance: 3))
```

A bare `DragGesture(minimumDistance: 1)` claimed the interaction on the first
pixel of movement, so double-click almost never landed — and while a field was
open, the same gesture sat over it and swallowed the clicks that would focus it.
`including: editing ? .subviews : .all` hands events to the field while it is
open.

`points` scrubs in **log space**: a budget running from ten thousand to fifty
million buries everything below a few million in the first tenth of a linear
drag.

### Overlays that follow the camera

The turn gizmo and section plane are drawn in SwiftUI but live in the scene, so
they must follow a camera SwiftUI cannot observe. `CameraClock` is a separate
`ObservableObject` ticked once per drawn frame — kept off `ViewModel` so a 60 Hz
signal does not re-evaluate the whole interface.

It only ticks when there is something to draw.

### The turn gizmo

**Screen-sized**, in a corner. Sizing the rings to the model was backwards:
zooming in is precisely when you want to square a wall, and it was the moment
the rings grew past the window.

Rotation direction is **measured, not derived** — the apparent direction flips
with whether the axis faces the eye and again with the screen's inverted y.
`gizmoScreenSign` rotates a probe by a hundredth of a radian and observes which
way its screen angle went. Correct for any camera, and impossible to get
backwards.

### Sheets

`Sheet` is the app's replacement for system alerts and submenus, which arrive in
Aqua with their own type and hierarchy. Export and About both use it.

---

## Testing

`Checks/run.sh` compiles each suite against the **real sources**, never a copy.
They are standalone `main.swift` programs, so they can drive Metal and the
renderer without an app bundle.

Two need care to reproduce:

- **`shaders`** compiles `Shaders.metal` with `xcrun metal`, links a
  `.metallib`, and renders offscreen.
- **`refinement`** constructs a real `Renderer` over a headless `MTKView`, and
  needs `default.metallib` beside the executable because
  `makeDefaultLibrary()` looks in the main bundle — which, for a command-line
  tool, is its own directory.

Adding a suite: write `Checks/<name>.swift` with top-level code, then add a
`run <name> Checks/<name>.swift <dependencies…>` line to `run.sh`.

---

## Extending

### A new data channel

1. Add a case to `VisualizationMode` and to `VisualizationModeType` in
   `ShaderTypes.h` — keep them in the same order.
2. Add the branch in `fragmentShader`.
3. Report availability in `VisualizationMode.isAvailable(hasColors:hasIntensity:)`
   so the bar can set it faint when the file cannot fill it.

### A new file format to read

Add a parser to `Parsers/` exposing
`static func parse(url:progress:) async throws -> PointCloud`, then a case in
`ViewModel.loadFile`. Build the interleaved array directly; anchor positions to
an origin in `Double`; skip non-finite coordinates.

### A new format to write

Add a case to `PointCloudFormat`, a `write…` function to `PointCloudWriter`, and
a case to its `switch`. It appears in the export sheet automatically. Add it to
`Checks/writers.swift` — the round-trip check is what catches a plausible but
malformed header.

---

## Shipping

### Before publishing to GitHub

- [ ] `git init` — the project is not yet a repository
- [x] ~~Add `.gitignore`~~ — added
- [ ] Choose a licence and add `LICENSE`
- [ ] Add screenshots to `docs/images/`
- [ ] Remove the 7 stray `.DS_Store` files (`find . -name .DS_Store -delete`)

```gitignore
.DS_Store
build/
DerivedData/
*.xcuserstate
xcuserdata/
```

### Before submitting to the App Store

Current state, honestly:

| | |
|---|---|
| Bundle identifier | `com.pulsedphotons.pro` |
| Version | 1.0 (build 1) |
| Deployment target | macOS 14.0 |
| Sandbox | **enabled** |
| Hardened runtime | **enabled** |
| Entitlements | `files.user-selected.read-write` only |

Still needed:

- [x] ~~An app icon.~~ Generated from the application's own mark at every
      size; regenerate with `Tools/icongen`.
- [ ] **A signing team and a distribution certificate.** Not configured.
- [x] ~~Copyright string.~~ Set.
- [x] ~~App category~~ — already set to `public.app-category.graphics-design`.
- [x] ~~Document types.~~ `Resources/Info.plist` declares LAS, PLY and XYZ as
      imported types, and `.onOpenURL` handles the open event. Verified: opening
      a file from Finder loads it.
- [x] ~~Privacy manifest.~~ `Resources/PrivacyInfo.xcprivacy`, and empty in
      every field - verified there are no required-reason API uses.
- [ ] **Sandbox check on the temp-file fallback.** `loadFile` copies to
      `NSTemporaryDirectory()` when a dropped URL cannot be opened directly;
      verify this path under a distribution build.
- [ ] Decide whether `.DS_Store` and multiple local copies of the project could
      cause bundle-identifier collisions during testing.

The sandbox entitlement set is already minimal and correct for a viewer: it
reads and writes only files the user picks.
