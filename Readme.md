# Pulsed Photons

A macOS point cloud viewer for measured light.

Reads light detection and ranging and photogrammetry scans, parsed through them fast,cut and square
and frame them, and hands data in whatever format the next tool needs.
Built on Metal, in Swift.

**macOS 14+ · Apple silicon and Intel · \~50M points on 18GB**

---

## What it does

**Reads** `.las` · `.ply` · `.xyz` · `.txt`
**Writes** `.ply` · `.xyz` · `.las` · `.png` · `.jpeg`

- **Four data channels** — solid, height, intensity, RGB. A channel the file
  does not contain is shown faint rather than hidden, so you can see what the
  data is missing.
- **X-ray** — accumulates every point along a ray instead of drawing the
  nearest, so structure emerges from density. Works over any channel.
- **Section** — a horizontal band cut through the cloud, thickness scrubbed,
  height set by panning. Combined with a top view and orthographic projection,
  this is a plan drawing.
- **Ground grid** — world-fixed, to scale, with the spacing chosen so roughly
  ten cells span the view at any zoom.
- **Level** — finds the ground plane by RANSAC and rotates the scan flat.
- **Turn** — a small gizmo for squaring a building to the grid by hand.
- **Select and delete** — marquee selection over the full cloud, with restore.
- **Multiple files** — open several scans into one scene; each is re-based onto
  the first file's origin so georeferenced data lines up.
- **Progressive refinement** — the view stays responsive while moving and fills
  in to the full cloud once still, a slice per frame, with no stall.

---

## Requirements

|          |                    |
| -------- | ------------------ |
| macOS    | 14.0 or later      |
| Xcode    | 15 or later        |
| Swift    | 5                  |
| Hardware | any Mac with Metal |

---

## Build and run

```bash
git clone https://github.com/Ex-risks/Pulsed-Photons.git
cd Pulsed-Photons
./run.sh
```

`run.sh` builds and launches in one step, and prints the binary's timestamp so
you can always tell whether you are looking at a fresh build. Pass `release` for
an optimised build:

```bash
./run.sh release
```

Or open `PulsedPhotonsPro.xcodeproj` and press ⌘R.

---

## Using it

Drop a file on the window, or ⌘O.

### The bar

One line, five categories of four:

```
FILE.LAS (5.9M)   SOLID HEIGHT INTENSITY RGB   SIZE POINTS XRAY SECTION
      TOP FRONT SIDE ISO   LEVEL TURN SELECT RESTORE   FIT GRID SUMI EXPORT
```

Each numeral is **scrubbable** — drag it to change the value, double-click to
type an exact one, ⌥-click to reset it. `POINTS` accepts `2M` and `500k`.

### Navigation

| Gesture        | Does                |
| -------------- | ------------------- |
| drag           | orbit               |
| ⌥ drag         | pan                 |
| ⇧ drag         | zoom                |
| ⌘ drag         | rotate the model    |
| scroll / pinch | zoom                |
| double-click   | fit to bounds       |
| ⌃ drag         | selection rectangle |

### Keys

|         |                   |           |                          |
| ------- | ----------------- | --------- | ------------------------ |
| `1`–`4` | data channel      | `⌘1`–`⌘4` | top / front / side / iso |
| `F`     | fit to bounds     | `G`       | ground grid              |
| `L`     | level to ground   | `T`       | turn handles             |
| `S`     | selection mode    | `⌫`       | delete selected          |
| `esc`   | clear selection   | `⌘E`      | export                   |
| `⌘O`    | open              | `⇧⌘O`     | add to scene             |
| `⇧⌘W`   | close point cloud |           |                          |

### Units

LAS files can store their unit in the coordinate system record, but many do not. PLY and XYZ files never do, so the app has to assume one. Assumed units appear in parentheses, for example `(metres)`. Click the unit to set the correct one. The app then uses that unit everywhere, including the scale bar, grid, and section thickness.

---

## Performance

Measured on an M3 Pro at a 2400×1600 drawable, with the real pipeline:

| Points | Frame   |
| -----: | ------: |
| 250K   | 0.87 ms |
| 2.5M   | 11.1 ms |
| 5M     | 23.2 ms |
| 10M    | 44 ms   |

Cost is linear in point count at **\~4.5 ns per point** and almost independent of
point size — the limit is primitive rate, not fill rate or vertex bandwidth.

Two budgets follow from that. While the camera moves, **3M points** keeps a 60fps
frame. Once it settles, the view refines to the whole cloud \*\*2M points per
frame\*\* into a texture that persists between frames, so a 50M-point scene
sharpens over about half a second.

Parsing runs at **71M points/second** for a 5M-point LAS and 36M/s at 20M, over
a memory-mapped file, straight into the interleaved vertex array.

### Ceiling

Roughly **49M points on an 18GB machine** — a quarter of physical memory,
divided by the 48-byte vertex, divided again by two because every displayed
point is resident twice: once in the working array and once in the Metal buffer.
See [Known limitations][1].

---

## Tests

```bash
./Checks/run.sh
```

Five suites, compiled against the real sources — never against a copy:

| Suite        | Covers                                                        |
| ------------ | ------------------------------------------------------------- |
| `grid`       | spacing stays legible across nine decades of zoom             |
| `units`      | LAS coordinate-system parsing, GeoTIFF and WKT                |
| `writers`    | every output format round-trips through the app's own parsers |
| `refinement` | sliced rendering is pixel-identical to a single pass          |
| `shaders`    | the real `Shaders.metal`, rendered offscreen                  |

They are standalone `main.swift` programs rather than an Xcode test target, so
they run without the app bundle and can drive Metal directly.

---

## Known limitations

- **Every point is resident twice** — once in the working array, once in the
  Metal buffer — which halves the practical ceiling. Dropping the working array
  and reading from the shared buffer would roughly double it, but touches
  selection, levelling and subsampling.
- **No LAZ.** Compressed LAS needs `laszip`; only uncompressed `.las` is read.
- **No LAS 1.4 extended point formats** (6–10) on write. Files are written as
  LAS 1.2, point format 2.
- **Coordinate systems are read but not written.** An exported LAS carries the
  correct origin and scale but no CRS record, so its unit is undeclared.
- **XYZ is written at millimetre precision** (three decimals). Fine for any
  scanner this reads; not lossless.
- **Two scans very far apart** lose precision when merged, because positions are
  `Float` relative to a single shared origin.

---

## Project layout

```
PulsedPhotonsPro/
  App/          entry point, menus, view model
  Models/       point cloud, units, visualisation modes
  Parsers/      LAS, PLY, XYZ readers and the writer
  Rendering/    Metal renderer, camera, grid, shaders
  Views/        SwiftUI interface, theme, toolbar
  Resources/    entitlements, asset catalogue
Checks/         headless test suites
Samples/        small test clouds
run.sh          build and launch
```

\~6,700 lines of Swift and Metal.

---

## Contributing

Issues and pull requests welcome. Before submitting:

1. `./Checks/run.sh` passes.
2. Both configurations build: `xcodebuild -scheme PulsedPhotonsPro -configuration Release build`.
3. New behaviour that could silently break has a check covering it.

The codebase favours comments that explain *why* a decision was made, especially
where the obvious approach was tried and measured and rejected. Please keep that.

---

## License

> MIT
