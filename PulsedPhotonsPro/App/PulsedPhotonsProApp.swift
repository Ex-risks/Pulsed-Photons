import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PulsedPhotonsProApp: App {
    @StateObject private var viewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { menus }
    }

    /// The complete index of what the application can do.
    ///
    /// Everything on the sheet appears here, and several things appear *only*
    /// here - the sheet carries what you touch while looking, the menus carry
    /// the rest. Key equivalents are dispatched by the system rather than by a
    /// view competing with the Metal canvas for first responder, so shortcuts
    /// work regardless of where focus sits.
    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Pulsed Photons") { viewModel.isShowingAbout = true }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Point Cloud…") { openFile(adding: false) }
                .keyboardShortcut("o", modifiers: .command)

            // Several scans of one site are one subject, so opening a second
            // file adds to the scene rather than replacing it. Each is re-based
            // onto the first file's origin as it arrives.
            Button("Add to Scene…") { openFile(adding: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(viewModel.pointCount == 0)
        }

        CommandGroup(replacing: .saveItem) {
            // One Export, which opens the application's own panel rather than a
            // system submenu - image sizes and cloud formats are the same
            // decision and belong in one place, in the same hand as the rest.
            Button("Export…") { viewModel.isExporting = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel.pointCount == 0)

            Divider()

            Button("Close Point Cloud") { viewModel.closeCloud() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(viewModel.pointCount == 0)
        }

        // Undo/redo, cut/copy/paste and Select All are text commands: every one
        // of them is permanently greyed out here, and they were most of what
        // the Edit menu contained.
        CommandGroup(replacing: .undoRedo) { }
        CommandGroup(replacing: .pasteboard) { }

        CommandGroup(replacing: .textEditing) {
            Toggle("Selection Mode", isOn: Binding(
                get: { viewModel.isSelectionMode },
                set: { on in
                    viewModel.isSelectionMode = on
                    if !on { viewModel.clearSelection() }
                }
            ))
            .keyboardShortcut("s", modifiers: [])

            Button("Delete Selected") { viewModel.deleteSelectedPoints() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!viewModel.hasSelection)

            Button("Clear Selection") { viewModel.clearSelection() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!viewModel.hasSelection)

            Divider()
            Button("Restore Original") { viewModel.restoreOriginal() }
                .disabled(!viewModel.hasEdits)

            Divider()

            // Levelling and turning change the object, not the view of it.
            Button("Level to Ground") { viewModel.levelToGround() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(viewModel.pointCount == 0)

            Button(viewModel.isTurning ? "Hide Turn Handles" : "Turn Model") {
                viewModel.isTurning.toggle()
                if viewModel.isTurning { viewModel.isSelectionMode = false }
            }
            .keyboardShortcut("t", modifiers: [])
            .disabled(viewModel.pointCount == 0)

            Button("Reset Rotation") { viewModel.resetTurn() }
                .disabled(viewModel.pointCount == 0)

            Divider()

            Menu("Up Axis") {
                Picker("Up Axis", selection: $viewModel.upAxis) {
                    Text("Z (scanned data)").tag(UpAxis.z)
                    Text("Y (graphics)").tag(UpAxis.y)
                }
                .pickerStyle(.inline)
            }
        }

        // Into the View menu the system already provides, rather than a second
        // one beside it. `CommandMenu("View")` does not merge with it - it adds
        // a duplicate, which is what put two View menus in the bar.
        CommandGroup(after: .toolbar) {
            Picker("Mode", selection: $viewModel.visualizationMode) {
                ForEach(VisualizationMode.allCases) { mode in
                    Text(mode.name).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            ForEach(Array(Camera.StandardView.allCases.enumerated()), id: \.element) { index, view in
                Button(view.rawValue.capitalized) { viewModel.setStandardView(view) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }

            Button("Fit to Bounds") { viewModel.fitToBounds() }
                .keyboardShortcut("f", modifiers: [])

            Button(viewModel.showGrid ? "Hide Ground Grid" : "Show Ground Grid") {
                viewModel.showGrid.toggle()
            }
            .keyboardShortcut("g", modifiers: [])
            .disabled(viewModel.pointCount == 0)

            Divider()

            Menu("Appearance") {
                Picker("Appearance", selection: $viewModel.isDarkMode) {
                    Text("Paper").tag(false)
                    Text("Sumi").tag(true)
                }
                .pickerStyle(.inline)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Controls") { showControls() }
        }
    }

    // MARK: - Panels

    private func openFile(adding: Bool) {
        let panel = NSOpenPanel()
        // Several files at once, opened in the order chosen.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["ply", "xyz", "txt", "las"].compactMap {
            UTType(filenameExtension: $0)
        }

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                // The first replaces or adds as asked; the rest always add, so
                // selecting four files opens four rather than only the last.
                for (index, url) in urls.enumerated() {
                    await viewModel.loadFile(url: url, adding: adding || index > 0)
                }
            }
        }
    }

    /// The one place the modifier vocabulary is written down. Everything here
    /// is otherwise learned by accident, which is how the scrubbable numerals
    /// went unnoticed.
    private func showControls() {
        let alert = NSAlert()
        alert.messageText = "Controls"
        alert.informativeText = """
        Drag — orbit
        ⌥ drag — pan
        ⇧ drag — zoom
        ⌘ drag — rotate the model
        ⌃ drag — select
        Scroll — zoom
        Double-click — fit

        Drag any numeral in the band to change it.
        Double-click a numeral to reset it.

        1–6 — modes
        ⌘1–⌘4 — top, front, side, iso
        F — fit    L — level    S — select
        """
        alert.runModal()
    }
}
