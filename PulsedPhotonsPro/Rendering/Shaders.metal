#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
    float intensity;
    float normalizedHeight;
};

// Height ramp: dark blue -> slate -> amber.
//
// Deliberately not the usual blue/cyan/green/yellow/red rainbow. That ramp is
// perceptually non-uniform (it invents banding at the cyan and yellow
// inflections) and is not colour-blind safe, so it misreports the data it is
// meant to describe. Blue->amber is the safest hue axis for CVD, and this ramp
// is monotonic in luminance so height still reads correctly in greyscale.
//
// The top stop is held below the light background's luminance (0.96) so the
// tallest points stay visible in both themes.
float4 heightRamp(float t) {
    t = saturate(t);
    float3 low  = float3(0.10, 0.14, 0.32);
    float3 mid  = float3(0.38, 0.45, 0.50);
    float3 high = float3(0.85, 0.62, 0.22);
    float3 rgb = (t < 0.5) ? mix(low, mid, t * 2.0) : mix(mid, high, (t - 0.5) * 2.0);
    return float4(rgb, 1.0);
}

// MARK: - Ground grid

struct GridVertexOut {
    float4 position [[position]];
    float weight;
    /// World position, carried so the fade can be evaluated per fragment. A
    /// grid line is long, so interpolating a radial function between its two
    /// ends would be badly wrong for any line passing near the centre.
    float3 world;
};

vertex GridVertexOut gridVertex(uint vertexID [[vertex_id]],
                                constant GridVertex *vertices [[buffer(BufferIndexGridVertices)]],
                                constant GridUniforms &uniforms [[buffer(BufferIndexGridUniforms)]]) {
    GridVertexOut out;
    GridVertex v = vertices[vertexID];
    out.position = uniforms.viewProjection * float4(v.position, 1.0);
    out.weight = v.weight;
    out.world = v.position;
    return out;
}

fragment float4 gridFragment(GridVertexOut in [[stage_in]],
                             constant GridUniforms &uniforms [[buffer(BufferIndexGridUniforms)]]) {
    // Dissolve with distance. Squared falloff, so the grid stays legible near
    // the subject and is gone well before the lines converge into moiré.
    float d = length(in.world - uniforms.fadeCentre) / max(uniforms.fadeRadius, 1e-5);
    float fade = saturate(1.0 - d * d);
    float alpha = uniforms.lineColor.a * in.weight * fade;
    if (alpha <= 0.002) { discard_fragment(); }
    return float4(uniforms.lineColor.rgb, alpha);
}

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant PointVertex *vertices [[buffer(BufferIndexVertices)]],
                              constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]]) {
    VertexOut out;

    PointVertex v = vertices[vertexID];
    out.position = uniforms.modelViewProjection * float4(v.position, 1.0);
    out.pointSize = uniforms.pointSize;
    out.color = v.color;
    out.intensity = v.intensity;

    // Project onto the up axis rather than assuming Z, so Height agrees with
    // whichever axis the camera is orbiting about.
    float height = dot(v.position, uniforms.heightAxis);
    float heightRange = uniforms.maxHeight - uniforms.minHeight;
    if (heightRange > 0.001) {
        out.normalizedHeight = (height - uniforms.minHeight) / heightRange;
    } else {
        out.normalizedHeight = 0.5;
    }

    // The section cut.
    //
    // Done here rather than by discarding in the fragment shader, so a point
    // outside the band costs nothing beyond this test - no rasterisation, no
    // fill. Pushing z past w puts the vertex outside the clip volume, which is
    // the defined way to drop a primitive without a geometry stage.
    if (uniforms.sectionHalf > 0.0 &&
        fabs(height - uniforms.sectionCentre) > uniforms.sectionHalf) {
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.pointSize = 0.0;
    }

    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               float2 pointCoord [[point_coord]],
                               constant Uniforms &uniforms [[buffer(BufferIndexUniforms)]]) {
    // Round splats. Metal rasterises points as squares, so the corners are
    // masked here; without this every point reads as an axis-aligned tile and
    // dense clouds turn into a grid.
    float2 coord = pointCoord * 2.0 - 1.0;
    float d = length(coord);
    if (d > 1.0) {
        discard_fragment();
    }

    // Anti-alias the rim analytically, via coverage.
    //
    // MSAA cannot do this: discard rejects an entire fragment rather than
    // individual samples, so a discard-masked circle stays hard-edged at any
    // sample count - measured, not assumed. `fwidth` gives the edge width in
    // this pixel; it is clamped so that small splats soften rather than
    // disappear.
    float edge = min(fwidth(d), 0.5);
    float coverage = (edge > 0.0) ? (1.0 - smoothstep(1.0 - edge, 1.0, d)) : 1.0;

    float4 baseColor = (uniforms.useVertexColors == 1) ? in.color : uniforms.pointColor;
    float4 finalColor = baseColor;

    switch (uniforms.visualizationMode) {
        case VisualizationModeSolid:
            break;

        case VisualizationModeHeight:
            finalColor = heightRamp(in.normalizedHeight);
            break;

        case VisualizationModeIntensity: {
            float lum = saturate(in.intensity);
            finalColor = float4(lum, lum, lum, 1.0);
            break;
        }

        case VisualizationModeRGB:
            finalColor = in.color;
            break;
    }

    // The overlay.
    //
    // At zero this is an opaque, depth-tested surface: the nearest point wins
    // and the cloud reads as skin. Above zero the pipeline accumulates instead,
    // so every point along a ray deposits and structure emerges from density -
    // the x-ray and silhouette readings, now available over any channel rather
    // than being channels of their own.
    //
    // Direction follows the ground. On sumi a deposit adds light. On paper it
    // must *subtract* light, and subtracting the colour itself would yield its
    // complement - so the complement is what gets subtracted, which is how
    // pigment actually works.
    float strength = uniforms.overlayStrength;
    if (strength > 0.0) {
        float quantum = coverage * strength * 0.05;
        float3 deposit = (uniforms.darkGround == 1) ? finalColor.rgb
                                                    : (1.0 - finalColor.rgb);
        return float4(deposit * quantum, quantum);
    }

    finalColor.a = coverage;
    return finalColor;
}
