#include <CoreImage/CoreImage.h>

using namespace metal;

extern "C" {
namespace coreimage {

/// Looks up the tone curve for scene value `x`. The table is a 1-pixel-high image sampled
/// uniformly in `x^(1/4)` over [0, maxEncoded], so most entries are spent in the shadows.
static float toneLookup(float x, sampler table, float maxEncoded, float count) {
    float position = clamp(pow(max(x, 0.0f), 0.25f) / maxEncoded, 0.0f, 1.0f) * (count - 1.0f) + 0.5f;
    return table.sample(table.transform(float2(position, 0.5f))).r;
}

/// Applies a tone curve the way Adobe's DNG SDK does (`RefBaselineRGBTone`): the largest and
/// smallest channels go through the curve and the middle channel keeps its relative position
/// between them. Hue is preserved, while saturation follows the curve's slope, so colors gain
/// saturation in the steep midtones and ease toward white where the curve flattens.
static float3 applyTone(float3 c, sampler table, float maxEncoded, float count) {
    float high = max(c.r, max(c.g, c.b));
    float low = min(c.r, min(c.g, c.b));
    float highOut = toneLookup(high, table, maxEncoded, count);
    float lowOut = toneLookup(low, table, maxEncoded, count);
    // The same expression maps the largest channel to highOut, the smallest to lowOut and
    // interpolates the middle one, so no sorting is needed.
    return high > low ? lowOut + (highOut - lowOut) * (c - low) / (high - low) : float3(highOut);
}

static float logLuminance(float3 c) {
    return log2(max(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 0.00006f));
}

float4 rgbTone(sampler image, sampler table, float maxEncoded, float count) {
    float4 pixel = image.sample(image.coord());
    return float4(applyTone(pixel.rgb, table, maxEncoded, count), pixel.a);
}

/// 0 below 0, then a quadratic that joins `x - 0.5` at 1.
static float ramp(float x) {
    return x <= 0.0f ? 0.0f : x < 1.0f ? 0.5f * x * x : x - 0.5f;
}

/// `rgbTone` after the local exposure change of Highlights and Shadows. `coefficients` holds
/// the guided filter's (a, b), scaled up to the image, so `a · L + b` is the edge-aware local
/// average of log2 luminance L; `offset` places it relative to mid gray after exposure. The
/// change in stops grows with the average's distance from mid gray, scaled by `highlights`
/// above it and `shadows` below it (at most 4 stops of distance). All channels get the same
/// gain, so hue is kept, and detail within a region keeps its contrast.
float4 rgbToneLocal(sampler image, sampler coefficients, sampler table, float maxEncoded, float count,
                    float offset, float highlights, float shadows, destination dest) {
    float4 pixel = image.sample(image.coord());
    float2 ab = coefficients.sample(coefficients.transform(dest.coord())).rg;
    float stops = ab.x * logLuminance(pixel.rgb) + ab.y + offset;
    float delta = highlights * ramp(stops) + shadows * min(ramp(-stops), 4.0f);
    return float4(applyTone(pixel.rgb * exp2(delta), table, maxEncoded, count), pixel.a);
}

// Guided filter on log2 luminance, run at low resolution (see LocalTone.swift).

float4 logLuminanceImage(coreimage::sample_t pixel) {
    return float4(logLuminance(pixel.rgb), 0.0f, 0.0f, 1.0f);
}

float4 squaredDeviation(coreimage::sample_t value, coreimage::sample_t mean) {
    float d = value.r - mean.r;
    return float4(d * d, 0.0f, 0.0f, 1.0f);
}

/// Self-guided filter coefficients: a = σ² / (σ² + ε), b = (1 − a) · mean. Variation well below
/// √ε stops is smoothed away, larger steps are kept as edges.
float4 guidedCoefficients(coreimage::sample_t mean, coreimage::sample_t variance, float epsilon) {
    float a = variance.r / (variance.r + epsilon);
    return float4(a, (1.0f - a) * mean.r, 0.0f, 1.0f);
}

}
}
