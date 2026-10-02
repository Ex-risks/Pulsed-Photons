# Tools

## icongen.swift

Draws the application icon at every size macOS asks for, straight into the asset
catalogue, and rewrites its `Contents.json`.

```bash
swiftc -O Tools/icongen.swift -o /tmp/icongen
/tmp/icongen PulsedPhotonsPro/Resources/Assets.xcassets/AppIcon.appiconset
```

The icon is the same mark the app draws on screen — a solid source point with
concentric wavefronts leaving it — rendered with Core Graphics rather than
exported by hand, so it can be regenerated from source whenever the mark changes.

Two deliberate departures from the on-screen mark:

- **Ink, not the interface's mid grey.** `ink500` on paper was invisible at
  32px against a light desktop. The icon uses `ink900`.
- **Fewer rings when small.** Below 24px only one ring is drawn, and below 48px
  two — three collapse into a grey smudge at those sizes.
