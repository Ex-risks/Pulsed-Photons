# Pulsed Photons

Technical documentation for the application architecture, rendering pipeline, file formats, testing, and extension points.

## Contents

- [Architecture](#architecture)
- [Data flow](#data-flow)
- [Coordinate precision](#coordinate-precision)
- [Rendering](#rendering)
- [Progressive refinement](#progressive-refinement)
- [Sampling](#sampling)
- [Camera](#camera)
- [File formats](#file-formats)
- [Interface](#interface)
- [Testing](#testing)
- [Extending](#extending)
- [Shipping](#shipping)

## Architecture

```text
PulsedPhotonsProApp
└── ContentView
    ├── MetalView
    ├── ModelOverlay
    ├── ToolbarView
    └── ViewModel
        └── Renderer
            ├── Camera
            └── GridRenderer
```

`ViewModel` is the boundary between the interface and renderer.

Views observe `ViewModel`. They do not access `Renderer` directly. Any renderer state needed by the interface is mirrored through published properties.

`Renderer` owns the point data because sampling, selection, levelling, bounds calculation, and GPU uploads all operate on the same arrays.

## Data flow

```text
File
  ↓
Parser
  ↓
PointCloud
  ↓
Renderer.loadPointCloud
  ├── originalVertices
  ├── workingVertices
  └── stratifiedSample
        ↓
     MTLBuffer
```

`PointCloud` is an immutable value containing:

- interleaved vertices
- bounds
- channel availability
- world origin
- units

Parsers build the interleaved vertex array directly to reduce peak memory use.

### PointVertex

`PointVertex` is defined in `ShaderTypes.h` and shared by Swift and Metal.

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

`scanAngle`, `returnNumber`, and `timeStamp` are loaded from LAS files but are not yet exposed as visualisation channels.

## Coordinate precision

Georeferenced point clouds can contain large world coordinates. Storing those coordinates directly as `Float` loses useful precision.

The parser therefore:

1. reads coordinates as `Double`
2. uses the first retained point as a provisional origin
3. stores point positions as local `Float` values relative to that origin
4. recentres the cloud on its bounding-box centre
5. stores the corresponding world position in `PointCloud.worldOrigin`

To recover a world coordinate:

```text
world position = local position + worldOrigin
```

Writers restore the world origin before exporting.

When files are merged, incoming clouds are rebased to the origin of the first cloud using `Double` arithmetic before conversion to `Float`.

Very widely separated scans can still lose precision. This becomes relevant at separations of hundreds of kilometres.

## Rendering

Points are rendered as `MTLPrimitiveType.point`.

### Point splats

Metal rasterises points as squares. The fragment shader clips each point to a circle and applies analytical edge smoothing.

```metal
float edge = min(fwidth(d), 0.5);
float coverage = (edge > 0.0)
    ? (1.0 - smoothstep(1.0 - edge, 1.0, d))
    : 1.0;
```

This avoids the memory and resolve cost of MSAA.

### Pipeline states

| State | Blend | Depth | Use |
|---|---|---|---|
| `pipelineState` | source-over | tested, writing | normal rendering |
| `pipelineStateAddInk` | additive | disabled | x-ray on light ground |
| `pipelineStateAddLight` | additive | disabled | x-ray on dark ground |

X-ray rendering uses the same point draw with accumulation enabled.

### Section cuts

Section clipping happens in the vertex shader. Points outside the section band are moved outside the clip volume before rasterisation.

```metal
if (uniforms.sectionHalf > 0.0 &&
    fabs(height - uniforms.sectionCentre) > uniforms.sectionHalf) {
    out.position = float4(0.0, 0.0, 2.0, 1.0);
    out.pointSize = 0.0;
}
```

### Height

Height is calculated by projecting each point onto the current up axis rather than assuming that `z` is vertical.

```swift
let axis = simd_normalize(
    camera.inverseModelRotation * camera.upAxis.vector
)
```

This keeps height visualisation correct after the model has been rotated or levelled.

### Grid

The grid uses a separate line-rendering pipeline.

It is:

- fixed in world space
- drawn before the point cloud
- depth-tested
- spaced using a 1-2-5 interval sequence

The spacing is chosen so roughly ten cells span the viewport.

## Progressive refinement

Large point clouds are not redrawn in full on every frame.

During camera movement, the renderer draws a reduced sample. Once the camera stops, it progressively fills a persistent colour and depth buffer.

```text
camera moving  → about 3M points
camera still   → full cloud in ~2M-point batches
```

Each frame displays the accumulated result.

This works because the display buffer is shuffled after stratified sampling, so every prefix is a representative sample of the cloud.

A change in rendering state invalidates the accumulation and starts a new frame.

`FrameState` contains the values that affect the rendered result. Progressive draw count is intentionally excluded because it changes while the same frame is being completed.

## Sampling

`Renderer.stratifiedSample(_:count:)` divides the source array into strata and selects one point from each.

The result is then shuffled.

This ensures that any prefix of the sampled array remains spatially representative, which is required for progressive refinement.

Resampling is debounced by 120 ms and runs away from the main actor.

## Camera

The camera uses an arcball controlled through target values. Position and rotation follow those targets using critically damped smoothing.

Canonical views use orthographic projection so plans and elevations remain measurable without perspective convergence.

Free orbiting uses perspective projection.

Model rotation is applied through the model matrix. Point positions themselves are not rewritten.

## File formats

### Reading

| Format | Support |
|---|---|
| LAS 1.0–1.4 | point formats 0–10 |
| PLY | ASCII and binary, little- and big-endian |
| XYZ / TXT | whitespace-separated coordinates with optional RGB |

LAS files are memory-mapped and parsed in a single pass.

Non-finite coordinates are skipped.

### Units

LAS files can declare their linear unit in the coordinate system record, but many do not. PLY and XYZ files do not store units.

When the unit is unknown, the app assumes one and shows it in parentheses, for example `(metres)`. Click the unit to set the correct value.

That unit is then used throughout the app, including the scale bar, grid, and section thickness.

For LAS files, units are read from:

- GeoTIFF keys in VLR `34735` for LAS 1.3 and earlier
- OGC WKT in VLR `2112` for LAS 1.4 when the WKT flag is set

### Writing

Exports are streamed in blocks of 262,144 vertices to avoid holding another complete copy of a large cloud in memory.

| Format | Output |
|---|---|
| PLY | binary little-endian, `double` positions, `uchar` RGB |
| XYZ | text, three decimal places, optional RGB |
| LAS | LAS 1.2, point format 2, 0.001 scale |

PLY positions are written as `double` so georeferenced coordinates retain their precision.

## Interface

The interface uses:

- one base type size
- two font weights
- one accent colour
- tonal contrast for hierarchy
- fixed spacing within control groups
- flexible spacing between groups

### ScrubValue

Numeric controls support:

- drag to change
- double-click to type
- Option-click to reset

The point-count control uses logarithmic scrubbing because its range spans from thousands to tens of millions.

### Camera-linked overlays

The turn gizmo and section plane are SwiftUI overlays that follow the rendered camera.

`CameraClock` publishes frame updates separately from `ViewModel` so camera animation does not force the entire interface to refresh at display rate.

### Turn gizmo

The gizmo is fixed to screen size rather than model size.

Its visible rotation direction is determined from the projected result rather than inferred from axis orientation.

### Sheets

Export and About use custom sheets instead of system alerts or submenus.

## Testing

Run all checks with:

```bash
Checks/run.sh
```

Each test suite compiles against the real application sources.

Important suites include:

- shader compilation and offscreen rendering
- progressive-refinement behaviour
- writer round trips

To add a test:

1. create `Checks/<name>.swift`
2. add it to `Checks/run.sh`
3. include any required source dependencies

## Extending

### Add a visualisation channel

1. Add a case to `VisualizationMode`.
2. Add the matching case to `VisualizationModeType` in `ShaderTypes.h`.
3. Keep both enums in the same order.
4. Add the rendering branch in `fragmentShader`.
5. Update `VisualizationMode.isAvailable(...)`.

### Add a readable file format

Create a parser in `Parsers/` with:

```swift
static func parse(
    url: URL,
    progress: ...
) async throws -> PointCloud
```

Then add the format to `ViewModel.loadFile`.

New parsers should:

- build the interleaved vertex array directly
- read coordinates using `Double`
- anchor coordinates to a local origin
- skip non-finite coordinates

### Add an export format

1. Add a case to `PointCloudFormat`.
2. Add the writer implementation to `PointCloudWriter`.
3. Add the format to the writer switch.
4. Add a round-trip test to `Checks/writers.swift`.

The export sheet reads from `PointCloudFormat`, so the new format appears automatically.

