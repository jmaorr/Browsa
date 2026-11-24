#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Performance panel's status card: the "Velaris" living gradient from 21st.dev, ported from its
// WebGL fragment shader to a SwiftUI colour effect. Three layers of 2D simplex noise, each pushed by
// the last, blend four colours over a dark background, with a centre glow, a vignette and film
// grain. Same noise and colour layering as the original. Changes: GLSL to Metal syntax, y flipped (SwiftUI's
// origin is top-left), the vignette measured on the card's own shape (Velaris's, on a wide card,
// blacked out both sides and left a swirl in the middle), a faint green floor, and a slow breath.

namespace velaris {

float3 mod289(float3 x) { return x - floor(x / 289.0) * 289.0; }
float2 mod289(float2 x) { return x - floor(x / 289.0) * 289.0; }
float3 permute(float3 x) { return mod289(((x * 34.0) + 1.0) * x); }

float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

} // namespace velaris

/// size: the card in points. time: seconds times speed (Velaris's u_time). grain: 0...1.
/// c0...c3: the four colours, light to dark. bg: the background under them. All colours 0...1 RGB.
[[ stitchable ]] half4 performanceGlow(float2 position, half4 color, float2 size, float time, float grain,
                                       float3 c0, float3 c1, float3 c2, float3 c3, float3 bg) {
    float2 uv = float2(position.x / max(size.x, 1.0), 1.0 - position.y / max(size.y, 1.0));
    float ratio = size.x / max(size.y, 1.0);
    float2 p = uv - 0.5;
    p.x *= ratio;
    // A little zoomed in, so the wide card shows two or three big sweeping shapes, as Velaris does
    // on a full-size hero.
    p *= 0.8;

    float t = time * 0.1;
    // Breathing: the whole field swells and settles about every 12 seconds.
    float breath = 0.5 + 0.5 * sin(time * 0.26);

    float n1 = velaris::snoise(p * 0.4 + float2(t * 0.2, -t * 0.3));
    float n2 = velaris::snoise(p * 0.55 + float2(-t * 0.15, t * 0.25) + n1 * 0.25);
    float n3 = velaris::snoise(p * 0.75 + float2(t * 0.1, -t * 0.2) + n2 * 0.2);

    // Never bare black: under the colours sits a deep shade of the darker green, so the whole card
    // reads as the status colour.
    float3 col = mix(bg, c2, 0.12);

    // Measured on the card itself (an ellipse to its edges), not the stretched noise space, and kept
    // gentle, so the colour reaches the corners.
    float dist = length((uv - 0.5) * 2.0);
    float vignette = 1.0 - smoothstep(0.45, 1.45, dist);

    float lift = 0.08 * breath;
    col = mix(col, c0, smoothstep(-0.35 - lift, 0.5, n1) * 0.85);
    col = mix(col, c1, smoothstep(-0.25 - lift, 0.6, n2) * 0.75);
    col = mix(col, c2, smoothstep(-0.3, 0.4, n3) * 0.6);
    col = mix(col, c3, smoothstep(0.0, 0.7, n1 * n2) * 0.5);

    float glow = smoothstep(1.2, 0.0, dist) * (0.22 + 0.08 * breath);
    col += c1 * glow;

    col = mix(col * 0.25, col, vignette);

    float g = fract(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453 + time);
    col += (g - 0.5) * grain * 0.1;

    return half4(half3(saturate(col)), 1.0h);
}
