#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Performance panel's status card: a living gradient. Two layers of simplex noise drift through
// three shades of the status colour (deep, mid, bright), with a soft glow in the top corner, a
// vignette and a little film grain. Our own take on the "animated simplex-noise background with
// colour blending, vignette glow and film grain" look; no code copied.
//
// The noise is Ashima Arts' 3D simplex noise (MIT, github.com/ashima/webgl-noise).

namespace perfglow {

float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }
float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);

    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);

    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);

    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;

    i = mod289(i);
    float4 p = permute(permute(permute(
                 i.z + float4(0.0, i1.z, i2.z, 1.0))
               + i.y + float4(0.0, i1.y, i2.y, 1.0))
               + i.x + float4(0.0, i1.x, i2.x, 1.0));

    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;

    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);

    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);

    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);

    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));

    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);

    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

    float4 m = max(0.5 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

} // namespace perfglow

/// size: the card in points. time: seconds, already scaled by how fast the card should move.
/// deep, mid, bright: the status colour's three shades, 0...1 RGB.
[[ stitchable ]] half4 performanceGlow(float2 position, half4 color, float2 size, float time,
                                       float3 deep, float3 mid, float3 bright) {
    float2 uv = position / max(size, float2(1.0));
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y) * 1.25;

    // Two slow layers; the second is pushed around by the first, so the bands fold into each other.
    float n1 = perfglow::snoise(float3(p * 0.9, time * 0.07));
    float n2 = perfglow::snoise(float3(p * 1.9 + float2(3.1, 1.7), time * 0.11 + n1 * 0.6));

    float3 col = mix(deep, mid, smoothstep(-0.65, 0.55, n1));
    col = mix(col, bright, smoothstep(0.15, 0.95, n2) * 0.55);

    // A soft light in the top-right corner, breathing a little.
    float2 glowAt = float2(0.88, 0.05);
    float d = length((uv - glowAt) * float2(aspect, 1.0));
    col += bright * 0.32 * exp(-d * 2.6) * (0.85 + 0.15 * sin(time * 0.6));

    // Vignette: darker toward the bottom-left, where the text sits, so white text stays readable.
    float v = length((uv - float2(0.62, 0.35)) * float2(1.0, 1.3));
    col *= 1.0 - 0.42 * smoothstep(0.25, 1.05, v);

    // Film grain, moving with time so it shimmers instead of sitting on the glass.
    float grain = perfglow::hash(position + fract(time * 3.7) * 97.0) - 0.5;
    col += grain * 0.035;

    return half4(half3(saturate(col)), 1.0h);
}
