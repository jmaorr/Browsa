#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Browsa orb as a live shader: a metallic roll of two vortices in the orb's own colours.
// The same maths runs in the web prototype, so a tweak there carries straight over.

namespace orb {

/// Turns the plane around `c`, most at the centre and fading with distance, so the middle of each
/// vortex moves fast and its outer bands lag and stretch.
float2 swirl(float2 p, float2 c, float a, float rad) {
    float2 d = p - c;
    float k = a * exp(-dot(d, d) / (rad * rad));
    float cs = cos(k), sn = sin(k);
    return c + float2(cs * d.x - sn * d.y, sn * d.x + cs * d.y);
}

/// Oxblood, red, orange, amber, yellow, a green kick, and a hint of cyan at the very top.
float3 ramp(float x) {
    const float3 c0 = float3(.55, .06, .03), c1 = float3(.86, .16, .04), c2 = float3(.95, .38, .02),
                 c3 = float3(.96, .62, .03), c4 = float3(.93, .83, .05), c5 = float3(.55, .85, .12),
                 c6 = float3(.35, .78, .85);
    x = clamp(x, 0.0, 1.0) * 6.0;
    if (x < 1.0) return mix(c0, c1, x);
    if (x < 2.0) return mix(c1, c2, x - 1.0);
    if (x < 3.0) return mix(c2, c3, x - 2.0);
    if (x < 4.0) return mix(c3, c4, x - 3.0);
    if (x < 5.0) return mix(c4, c5, x - 4.0);
    return mix(c5, c6, x - 5.0);
}

/// A smooth minimum, so the two vortices' rings meet without a seam.
float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/// Two vortices, like the icon's orb, over a diagonal sweep that rolls through them.
float field(float2 p, float t) {
    // Rushes at first, then eases as the bands stretch out.
    float roll = 1.6 * (1.0 - exp(-t * 0.6)) + 0.12 * t;
    float2 c1 = float2(-0.42 + 0.06 * sin(t * 0.3), 0.08 * cos(t * 0.27));
    float2 c2 = float2(0.40 + 0.05 * cos(t * 0.33), -0.06 + 0.05 * sin(t * 0.31));
    p = swirl(p, float2(0.0), 0.25 * sin(roll * 0.7), 1.4);
    p = swirl(p, c1, 2.4 + 0.35 * roll, 0.42);
    p = swirl(p, c2, -2.0 - 0.3 * roll, 0.48);
    float a = length(p - c1), b = length(p - c2);
    return 0.55 * smoothstep(0.75, 0.0, smin(a, b * 1.05, 0.3)) + 0.45 * (0.5 + 0.5 * sin(p.x * 1.7 - p.y * 2.3 + 0.8 - roll * 1.8));
}

/// The orb's colour at a point, lit like polished metal. Scales with the view's height.
float3 colour(float2 position, float2 size, float t) {
    float2 p = (position - 0.5 * size) / size.y;
    float e = 1.5 / size.y;
    float v = field(p, t);
    float2 g = float2(field(p + float2(e, 0), t) - v, field(p + float2(0, e), t) - v) / e;
    float3 n = normalize(float3(-g * 0.06, 1.0));
    float3 c = ramp(v * 0.84 + 0.02);
    const float3 light = normalize(float3(-0.4, -0.5, 0.75));
    float diffuse = saturate(dot(n, light));
    float spec = pow(saturate(dot(reflect(-light, n), float3(0, 0, 1))), 24.0);
    c *= 0.75 + 0.35 * diffuse;
    c += float3(1.0, 0.93, 0.8) * spec * 0.35;
    // Steep creases go darker, like the seams between the orb's bands.
    return c * (1.0 - 0.35 * smoothstep(6.0, 22.0, length(g)));
}

} // namespace orb

/// Fills the view edge to edge with the moving orb.
[[ stitchable ]] half4 orbFill(float2 position, half4 color, float2 size, float time) {
    return half4(half3(orb::colour(position, size, time)), 1.0h);
}

/// A warm glow of orb colour that swells up from the bottom edge and sinks back as `progress` runs 0 to 1.
/// Premultiplied, so it lays over whatever is behind it.
[[ stitchable ]] half4 orbGlow(float2 position, half4 color, float2 size, float time, float progress) {
    float3 c = orb::colour(position, size, time);
    float y = 1.0 - position.y / size.y;                       // 0 at the bottom edge
    float rise = smoothstep(0.0, 0.45, progress), sink = smoothstep(0.5, 1.0, progress);
    float reach = mix(0.08, 0.55, rise) * (1.0 - 0.5 * sink);   // swells up, then sinks back down
    float edge = 0.35 + 0.08 * sin(position.x / size.x * 6.2832 * 1.5 + time * 2.0);
    float a = 1.0 - smoothstep(reach * edge * 2.0, reach * (edge * 2.0 + 0.5), y);
    a *= rise * (1.0 - sink) * 0.8;
    return half4(half3(c * a), half(a));
}
