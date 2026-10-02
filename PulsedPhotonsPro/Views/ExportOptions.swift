import SwiftUI

/// The two choices that change what an exported image contains.
///
/// Presented as an accessory to the save panel rather than as a separate step,
/// so the decision sits with the act of writing the file - and so the image
/// dimensions can be stated before it is written rather than discovered after.
struct ExportOptions: View {
    @ObservedObject var viewModel: ViewModel
    let total: Int
    let drawableSize: CGSize

    private var pixels: String {
        let w = Int(drawableSize.width * viewModel.exportScale)
        let h = Int(drawableSize.height * viewModel.exportScale)
        let mp = Double(w * h) / 1_000_000
        return String(format: "%d × %d  ·  %.1f MP", w, h, mp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Text("scale")
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .foregroundColor(Theme.ink500)

                Picker("", selection: $viewModel.exportScale) {
                    ForEach([1, 2, 3, 4], id: \.self) { Text("\($0)×").tag(CGFloat($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)

                Text(pixels)
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300)
            }

            HStack(spacing: Theme.Space.m) {
                Text("points")
                    .font(Theme.Text.word)
                    .tracking(Theme.Text.tracking)
                    .foregroundColor(Theme.ink500)

                // Splats stay pixel-constant, so more points resolve finer
                // structure rather than magnifying the same marks.
                Slider(value: Binding(
                    get: { Double(viewModel.exportPointCount) },
                    set: { viewModel.exportPointCount = Int($0) }
                ), in: 10_000...Double(max(total, 10_001)))
                .frame(width: 168)

                Text("\(ViewModel.compactCount(viewModel.exportPointCount)) of \(ViewModel.compactCount(total))")
                    .font(Theme.Text.numeral)
                    .foregroundColor(Theme.ink300)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}
