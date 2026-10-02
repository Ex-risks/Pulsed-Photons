# Pulsed Photons

A macOS viewer for measured light.

Light detection and ranging records space through measured returns forming point clouds. Pulsed Photons renders large volumetric point-cloud datasets in real time for interactive inspection, sectioning, alignment, combination, and export.

Built in Swift and Metal.

**macOS 14+ · Apple silicon and Intel · ~50M points on an 18GB Mac**

---

## Features

**Reads:** `.las` · `.ply` · `.xyz` · `.txt`  
**Writes:** `.las` · `.ply` · `.xyz` · `.png` · `.jpeg`

- **Data channels**  
  View the cloud as solid colour, height, intensity or RGB. Channels missing from the source remain visible but disabled, so you can see what the file contains.

- **X-ray**  
  Accumulates points through the depth of the cloud rather than showing only the nearest surface. Density and internal structure become visible.

- **Sections**  
  Cut a horizontal band through the cloud and scrub its thickness and height. Combine it with a top orthographic view for a measured plan section.

- **Ground grid**  
  A world-fixed grid that stays to scale and adjusts its spacing as you zoom.

- **Level**  
  Finds the ground plane with RANSAC and rotates the scan level.

- **Turn**  
  Square buildings, rooms and other geometry to the grid by hand.

- **Select and delete**  
  Marquee-select points from the full cloud, remove them and restore the original data when needed.

- **Multiple files**  
  Open several scans in one scene. Georeferenced files are rebased to a common origin so they remain aligned.

- **Progressive refinement**  
  Keeps the view responsive while the camera moves, then progressively resolves the complete cloud once the view is still.

---

## Requirements

| | |
|---|---|
| macOS | 14.0 or later |
| Hardware | Any Mac with Metal |
| Xcode | 15 or later, for building from source |
| Swift | 5 |

---

## Build

Clone the repository:

```bash
git clone https://github.com/Ex-risks/Pulsed-Photons.git
cd Pulsed-Photons
```

Build and launch:

```bash
./run.sh
```

For an optimised build:

```bash
./run.sh release
```

Or open `PulsedPhotonsPro.xcodeproj` in Xcode and press `⌘R`.

If you only want to use the application, download the latest ready-made build from **Releases**.

---

## Usage

Drop a supported file onto the window, or press `⌘O`.

### Toolbar

The main controls sit in a single bar:

```text
FILE.LAS (5.9M)   SOLID HEIGHT INTENSITY RGB   SIZE POINTS XRAY SECTION
      TOP FRONT SIDE ISO   LEVEL TURN SELECT RESTORE   FIT GRID SUMI EXPORT
```

Numeric controls are scrub-enabled:

- drag to change
- double-click to enter an exact value
- Option-click to reset

`POINTS` also accepts values such as `2M` and `500k`.

### Navigation

| Gesture | Action |
|---|---|
| drag | orbit |
| `⌥` drag | pan |
| `⇧` drag | zoom |
| `⌘` drag | rotate model |
| scroll / pinch | zoom |
| double-click | fit to bounds |
| `⌃` drag | select |

### Keyboard

| Key | Action | Key | Action |
|---|---|---|---|
| `1`–`4` | data channel | `⌘1`–`⌘4` | top / front / side / iso |
| `F` | fit to bounds | `G` | grid |
| `L` | level | `T` | turn |
| `S` | selection mode | `⌫` | delete selection |
| `Esc` | clear selection | `⌘E` | export |
| `⌘O` | open | `⇧⌘O` | add file |
| `⇧⌘W` | close point cloud | | |

### Units

LAS files can declare their linear unit in the coordinate-system record, but many do not. PLY and XYZ files do not store units.

When the unit is unknown, Pulsed Photons assumes one and shows it in parentheses, for example `(metres)`. Click the unit to set the correct value.

The app then uses that unit throughout, including the scale bar, grid and section thickness.

---

## Performance

Measured on an M3 Pro at a 2400 × 1600 drawable using the production rendering pipeline:

| Points | Frame time |
|---:|---:|
| 250K | 0.87 ms |
| 2.5M | 11.1 ms |
| 5M | 23.2 ms |
| 10M | 44 ms |

Rendering cost scales approximately linearly at **~4.5 ns per point** and changes little with point size. The main constraint is primitive throughput rather than fill rate or vertex bandwidth.

While the camera moves, the renderer targets about **3M points** to keep interaction responsive. Once the camera stops, it progressively refines to the full cloud in batches of roughly **2M points per frame**.

LAS parsing reaches approximately **71M points/s** on a 5M-point file and **36M points/s** at 20M points, reading from a memory-mapped file directly into the interleaved vertex array.

### Memory

A practical ceiling is roughly **49M points on an 18GB Mac**.

Each displayed point is currently held twice: once in the working CPU-side array and once in the Metal buffer. At 48 bytes per vertex, memory becomes the main constraint before rendering does.

---

## Tests

Run the full suite with:

```bash
./Checks/run.sh
```

The checks compile against the application sources rather than copies or fixtures.

| Suite | Covers |
|---|---|
| `grid` | grid spacing across large zoom ranges |
| `units` | LAS GeoTIFF and WKT unit parsing |
| `writers` | export round trips through the app's parsers |
| `refinement` | progressive rendering against a single-pass render |
| `shaders` | the production `Shaders.metal`, rendered offscreen |

The suites are standalone Swift programs rather than an Xcode test target, allowing them to exercise Metal and renderer code directly.

---

## Limitations

- **No LAZ.** Convert compressed `.laz` files to `.las` first.
- **LAS export uses LAS 1.2, point format 2.** Extended LAS 1.4 point formats are not currently written.
- **Coordinate systems are read but not written.** Exported LAS files retain their origin and scale but do not currently include a CRS record.
- **XYZ export uses three decimal places.**
- **Very distant scans can lose precision when merged.** Files share one local `Float` coordinate space.
- **Point data is held twice in memory.** This currently sets the practical ceiling for very large scenes.

---

## Structure

```text
PulsedPhotonsPro/
  App/          application entry point, menus, view model
  Models/       point cloud, units, visualisation modes
  Parsers/      LAS, PLY and XYZ readers, writers
  Rendering/    Metal renderer, camera, grid, shaders
  Views/        SwiftUI interface, theme, toolbar
  Resources/    assets and entitlements

Checks/         headless test suites
Samples/        small example point clouds
run.sh          build and launch
```

The project contains roughly 6,700 lines of Swift and Metal.

---

## Background

Pulsed Photons began as research code I developed during PhD in **Architectural Computation at the University of Edinburgh** in a thesis entitled  [*Ex-risk architecture: anticipating existential catastrophes through design*](https://era.ed.ac.uk/items/95ff0ab9-a324-45b6-ae39-4a4fb7239bea), where I used architecture to understand the spatial logic of extinction: how compound climate-related events reorganise human and more-than-human ecologies in a catastrophic manner. 

Large-scale point-cloud datasets were central to that work. I wrote custom code to visualise measured environments volumetrically, often section and reorient them, and use them as architectural evidence in an autographic register. The software existed as research infrastructure for specific investigations. Pulsed Photons formalises that code into a standalone tool for reading, sectioning, aligning, and exporting large point clouds without first passing through a larger data modelling environment.

I continued developing it at the **Institute for Design Informatics, University of Edinburgh**, where I introduced it to the **2024–25 MA/MSc Design Informatics cohort** as a field instrument, connecting terrestrial scanning, ecological observation and spatial interaction in a composite infrastructure.

---

## Acknowledgements

Pulsed Photons is the result of a longer ecology of design research and pedagogical experiments at the University of Edinburgh carried between 2016-2022.

At different stages, its development has been made possible through funding, institutional support, research programmes, equipment access and opportunities to test the work with students and researchers. This includes support associated with:

- **Edinburgh Futures Institute**
- **Data-Driven Innovation**
- **Centre for Data, Culture & Society**
- **Institute for Design Informatics**
- **uCreate Makerspace**

---

## Contributing

Issues and pull requests are welcome.

Before submitting a change:

1. Run `./Checks/run.sh`.
2. Confirm the Release configuration builds.
3. Add a check for behaviour that could otherwise fail silently.

Comments should explain **why** a non-obvious decision exists, particularly where a simpler approach was tested and rejected.

---

## License

MIT
