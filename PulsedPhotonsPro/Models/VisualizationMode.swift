import Foundation

/// What colours a point - the channel, and only the channel.
///
/// X-Ray and Silhouette used to sit here as siblings, but they were never
/// channels: they were ways of *reading* whatever channel was chosen. They are
/// now a single overlay with a strength, orthogonal to this, so any channel can
/// be read either as an opaque surface or as accumulating structure. That also
/// retired the opacity control, which only ever existed to expose them.
///
/// Raw values must stay in sync with `VisualizationModeType` in ShaderTypes.h.
enum VisualizationMode: Int, CaseIterable, Identifiable, Hashable {
    case solid = 0
    case height = 1
    case intensity = 2
    case rgb = 3

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .solid: return "Solid"
        case .height: return "Height"
        case .intensity: return "Intensity"
        case .rgb: return "RGB"
        }
    }

    /// Whether the loaded file actually carries this channel.
    ///
    /// Shown by emphasis in the selector rather than by a separate list of
    /// channels: the modes themselves say what the file contains.
    func isAvailable(hasColors: Bool, hasIntensity: Bool) -> Bool {
        switch self {
        case .solid, .height: return true       // position is always present
        case .intensity: return hasIntensity
        case .rgb: return hasColors
        }
    }
}
