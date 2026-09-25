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
float4 rgbTone(sampler image, sampler table, float maxEncoded, float count) {
    float4 pixel = image.sample(image.coord());
    float3 c = pixel.rgb;
    float high = max(c.r, max(c.g, c.b));
    float low = min(c.r, min(c.g, c.b));
    float highOut = toneLookup(high, table, maxEncoded, count);
    float lowOut = toneLookup(low, table, maxEncoded, count);
    // The same expression maps the largest channel to highOut, the smallest to lowOut and
    // interpolates the middle one, so no sorting is needed.
    float3 mapped = high > low ? lowOut + (highOut - lowOut) * (c - low) / (high - low) : float3(highOut);
    return float4(mapped, pixel.a);
}

}
}
