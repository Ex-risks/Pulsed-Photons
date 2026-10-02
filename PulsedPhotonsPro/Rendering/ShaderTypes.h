#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Buffer indices
typedef enum {
    BufferIndexVertices = 0,
    BufferIndexUniforms = 1,
    BufferIndexGridVertices = 2,
    BufferIndexGridUniforms = 3
} BufferIndex;

// Visualization modes.
// Each mode is tied to a channel that actually exists in the source data:
// position (Solid, X-Ray), Z (Height), the intensity channel (Intensity),
// and per-point RGB (RGB). Keep in sync with VisualizationMode.swift.
typedef enum {
    VisualizationModeSolid = 0,
    VisualizationModeHeight = 1,
    VisualizationModeIntensity = 2,
    VisualizationModeRGB = 3
} VisualizationModeType;

// Vertex data for each point.
// scanAngle/returnNumber/timeStamp are carried from LAS but not yet consumed by
// any mode; they are retained for planned derived channels.
typedef struct {
    simd_float3 position;
    simd_float4 color;
    float intensity;
    float scanAngle;
    float returnNumber;
    float timeStamp;
} PointVertex;

// Uniforms passed to shaders. Every field here is read by Shaders.metal.
typedef struct {
    simd_float4x4 modelViewProjection;
    simd_float4 pointColor;
    // Unit vector along the up axis. Height mode projects onto it rather than
    // reading position.z, so the colour ramp follows the same axis the camera
    // orbits about. minHeight/maxHeight are the bounds projected onto it.
    simd_float3 heightAxis;
    float pointSize;
    float minHeight;
    float maxHeight;
    /// 0 renders an opaque, depth-tested surface. Above 0 the renderer
    /// switches to an accumulating pipeline and this scales the quantum each
    /// point deposits, so structure builds out of density.
    float overlayStrength;
    /// A band along the up axis, in the same units as minHeight/maxHeight.
    /// Points outside it are cut in the vertex shader. A half-thickness of 0
    /// leaves the cloud whole.
    float sectionCentre;
    float sectionHalf;
    int visualizationMode;
    int useVertexColors;
    /// Deposits subtract from paper and add to sumi; the shader has to know
    /// which ground it is working on to emit the right quantity.
    int darkGround;
} Uniforms;

// MARK: - Ground grid

// One end of a grid line, in world space.
//
// The grid is deliberately not subject to the model matrix: it is the datum the
// model turns against, so TURN squares a building to it rather than dragging it
// along.
typedef struct {
    simd_float3 position;
    /// 1 for the emphasised lines, less for the rest. Carried per vertex so the
    /// hierarchy costs no extra draw.
    float weight;
} GridVertex;

typedef struct {
    /// View-projection only. No model matrix, by design - see GridVertex.
    simd_float4x4 viewProjection;
    simd_float4 lineColor;
    /// Centre of the fade, on the ground plane, and the distance over which the
    /// grid dissolves. Without this the lines converge into moiré at the
    /// horizon and the drawing turns to noise.
    simd_float3 fadeCentre;
    float fadeRadius;
} GridUniforms;

#endif /* ShaderTypes_h */
