#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Browsa orb as a live shader: slow domain-warped noise mapped onto the orb's own colours.
// The same maths runs in the web prototype, so a tweak there carries straight over.

namespace orb {

float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    const float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = m * p; a *= 0.5; }
    return v;
}

/// Oxblood, red-orange, orange, amber, yellow, a touch of lime: the orb artwork's ramp.
float3 ramp(float x) {
    const float3 c0 = float3(.62, .10, .04), c1 = float3(.83, .17, .05), c2 = float3(.94, .36, .02),
                 c3 = float3(.95, .63, .02), c4 = float3(.92, .84, .04), c5 = float3(.68, .86, .10);
    x = clamp(x, 0.0, 1.0) * 5.0;
    if (x < 1.0) return mix(c0, c1, x);
    if (x < 2.0) return mix(c1, c2, x - 1.0);
    if (x < 3.0) return mix(c2, c3, x - 2.0);
    if (x < 4.0) return mix(c3, c4, x - 3.0);
    return mix(c4, c5, x - 4.0);
}

/// The orb's colour at a point. `uv` is in units of the view's height, so it scales with the window.
float3 colour(float2 uv, float t) {
    float2 q = float2(fbm(uv * 0.7 + float2(0.0, t * 0.06)), fbm(uv * 0.7 + float2(5.2, 1.3) - t * 0.045));
    float2 r = float2(fbm(uv * 0.8 + 2.4 * q + float2(1.7, 9.2) + t * 0.09),
                      fbm(uv * 0.8 + 2.4 * q + float2(8.3, 2.8) - t * 0.075));
    float f = fbm(uv * 0.6 + 2.8 * r);
    // Spread across the ramp, then fold into soft rings like the orb's lobes.
    float x = smoothstep(0.40, 0.72, f);
    float ring = 0.5 + 0.5 * sin(x * 7.0 + q.x * 4.0 - t * 0.4);
    float3 c = ramp(mix(x, ring, 0.22) * 0.9);
    return mix(c, float3(1.0, 0.95, 0.84), smoothstep(0.9, 1.0, x * ring) * 0.35);
}

} // namespace orb

/// Fills the view edge to edge with the moving orb.
[[ stitchable ]] half4 orbFill(float2 position, half4 color, float2 size, float time) {
    return half4(half3(orb::colour(position / size.y, time)), 1.0h);
}

/// A glow of orb colour that rises from the bottom edge and falls away as `progress` runs 0 to 1.
/// Premultiplied, so it lays over whatever is behind it.
[[ stitchable ]] half4 orbGlow(float2 position, half4 color, float2 size, float time, float progress) {
    float3 c = orb::colour(position / size.y, time);
    float y = 1.0 - position.y / size.y;                       // 0 at the bottom edge
    float reach = mix(0.04, 0.6, smoothstep(0.0, 0.5, progress));
    float edge = 0.35 + 0.08 * sin(position.x / size.x * 6.2832 * 1.5 + time * 2.0);
    float a = 1.0 - smoothstep(reach * edge * 2.0, reach * (edge * 2.0 + 0.35), y);
    a *= 1.0 - smoothstep(0.45, 1.0, progress);
    a *= 0.9;
    return half4(half3(c * a), half(a));
}
