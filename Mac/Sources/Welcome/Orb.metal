#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The welcome intro's liquid metal: Paper Shaders' Liquid Metal (Apache 2.0,
// github.com/paper-design/shaders, packages/shaders/src/shaders/liquid-metal.ts), by way of
// Torqa's SwiftUI port, driven from two sources instead of one image. Each source glows, grows
// outward until the metal fills the view, and where the two meet their stripes bend into each
// other. The metal grows out of `base`, the page colour, so light and dark mode each start from
// their own page. The same maths runs in the Welcome Lab web prototype.
//
// Departures from Paper:
//  1. Stitchable functions get no screen-space derivatives, so fwidth() is a forward difference
//     one pixel right and one pixel down.
//  2. The chrome is run through a heat ramp (oxblood, red, orange, yellow) with a splash of green
//     on the brightest bands, the colours of the app icon, and the chromatic fringe re-added.

namespace orb {

constant float PI = 3.14159265358979323846;

float glslMod(float x, float y) { return x - y * floor(x / y); }
float2 glslMod(float2 x, float y) { return x - y * floor(x / y); }
float3 glslMod(float3 x, float y) { return x - y * floor(x / y); }

float2 rotate(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float3 permute(float3 x) { return glslMod(((x * 34.0) + 1.0) * x, 289.0); }

float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12 = float4(x12.xy - i1, x12.zw);
    i = glslMod(i, 289.0);
    float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m; m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g = float3(a0.x * x0.x + h.x * x0.y, a0.yz * x12.xz + h.yz * x12.yw);
    return 130.0 * dot(m, g);
}

/// The icon's heat colours, for the glow ahead of the metal.
float3 heat(float x) {
    const float3 c[9] = { float3(.05, .01, .01), float3(.47, .05, .02), float3(.80, .12, .03),
                          float3(.93, .30, .03), float3(.95, .55, .05), float3(.94, .78, .07),
                          float3(.78, .86, .10), float3(.16, .74, .25), float3(.24, .74, .86) };
    float s = saturate(x) * 8.0;
    int i = int(min(floor(s), 7.0));
    return mix(c[i], c[i + 1], s - float(i));
}

float3 ramp4(float l, float3 a, float3 b, float3 c, float3 d) {
    float s = l * 3.0;
    if (s < 1.0) return mix(a, b, s);
    if (s < 2.0) return mix(b, c, s - 1.0);
    return mix(c, d, s - 2.0);
}

struct Flow { float direction, bumpEarly, bump, noise, edge, d1, d2; };

/// Everything in Paper's main() that shapes the stripe direction (see Torqa's LiquidMetal.metal).
Flow flow(float2 uv, float edgeIn, float t) {
    const float cycleWidth = 2.0, distortion = 0.07, contour = 0.4, angle = 70.0;
    Flow f;
    float2 ru = rotate(uv - 0.5, (-angle + 70.0) * PI / 180.0) + 0.5;
    f.d1 = ru.x - ru.y;
    f.d2 = ru.x + ru.y;
    float2 g = uv - 0.5;
    float dist = length(g + float2(0.0, 0.2 * f.d1));
    g = rotate(g, (0.25 - 0.2 * f.d1) * PI);
    float direction = g.x;
    float uy = max(uv.y, 0.0);
    float bump = 1.0 - pow(1.8 * dist, 1.2);
    bump *= pow(uy, 0.3);
    f.bumpEarly = bump;
    float noise = snoise(uv - t);
    float edge = edgeIn + (1.0 - edgeIn) * distortion * noise;
    direction += f.d1;
    direction -= 2.0 * noise * f.d1 * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
    direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, contour));
    direction -= 1.7 * edge * smoothstep(0.5, 1.0, contour);
    direction += 0.2 * pow(contour, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));
    bump *= clamp(pow(uy, 0.1), 0.3, 1.0);
    direction *= (0.1 + (1.1 - edge) * bump);
    direction *= (0.4 + 0.6 * (1.0 - smoothstep(0.5, 1.0, edge)));
    direction += 0.18 * (smoothstep(0.1, 0.2, uy) * (1.0 - smoothstep(0.2, 0.4, uy)));
    direction += 0.03 * (smoothstep(0.1, 0.2, 1.0 - uy) * (1.0 - smoothstep(0.2, 0.4, 1.0 - uy)));
    direction *= (0.5 + 0.5 * pow(uy, 2.0));
    direction *= cycleWidth;
    direction -= t;
    f.direction = direction; f.bump = bump; f.noise = noise; f.edge = edge;
    return f;
}

float colorChanges(float c1, float c2, float sp, float3 w, float blur, float bump) {
    blur = max(blur, 1e-4);
    float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, sp));
    float b = w.x;
    ch = mix(ch, c2, smoothstep(b, b + 2.0 * blur, sp));
    bump = smoothstep(0.2, 0.8, bump);
    b = w.x + 0.4 * (1.0 - bump) * w.y; ch = mix(ch, c1, smoothstep(b, b + 2.0 * blur, sp));
    b = w.x + 0.5 * (1.0 - bump) * w.y; ch = mix(ch, c2, smoothstep(b, b + 2.0 * blur, sp));
    b = w.x + w.y;                      ch = mix(ch, c1, smoothstep(b, b + 2.0 * blur, sp));
    float gt = (sp - w.x - w.y) / w.z;
    float gr = mix(c1, c2, smoothstep(0.0, 1.0, gt));
    return mix(ch, gr, smoothstep(b, b + 0.5 * blur, sp));
}

/// The two sources at time `t`: where each sits, how far each has grown, and the field they make.
struct Sources { float2 d1, d2; float q1, q2, g1, g2, field; };

Sources sources(float2 p, float t) {
    Sources s;
    float slow = t * 0.22;
    float2 c1 = float2(-0.30 + 0.07 * sin(slow * 0.9), 0.05 * cos(slow * 0.7) + 0.03);
    float2 c2 = float2(0.32 + 0.06 * cos(slow * 0.8), -0.05 + 0.05 * sin(slow * 0.6));
    s.d1 = p - c1; s.d2 = p - c2;
    s.q1 = dot(s.d1, s.d1); s.q2 = dot(s.d2, s.d2);
    s.g1 = smoothstep(0.0, 4.5, t); s.g2 = smoothstep(0.9, 5.5, t);
    float r1 = s.g1 * s.g1 * 1.4, r2 = s.g2 * s.g2 * 1.25;
    s.field = r1 * r1 / max(s.q1, 1e-5) + r2 * r2 / max(s.q2, 1e-5);
    return s;
}

/// Each source's own uv, blended by nearness, so the stripes bend where the two meet.
float2 sourceUV(Sources s) {
    const float S = 0.62;
    float w = s.q2 / (s.q1 + s.q2 + 1e-5);
    return mix(s.d2 / (2.0 * S) + 0.5, s.d1 / (2.0 * S) + 0.5, w);
}

float sourceEdge(Sources s) {
    float e1 = smoothstep(0.0, 0.85, sqrt(s.q1)), e2 = smoothstep(0.0, 0.85, sqrt(s.q2));
    return saturate(sqrt(e1 * e2) * 1.05);
}

float3 metal(float2 position, float2 size, float time, float3 base, float green) {
    // y runs down, as in Torqa's port; the view's height is the unit.
    float2 p = (position - 0.5 * size) / size.y;
    float px = 1.0 / size.y;
    float t = 0.3 * (time + 2.8);

    Sources s = sources(p, time);
    Sources sx = sources(p + float2(px, 0.0), time);
    Sources sy = sources(p + float2(0.0, px), time);

    // Coverage: the metal's front, anti-aliased by the field's own change across a pixel.
    float cov = smoothstep(0.75, 1.25, s.field);

    float edge = pow(sourceEdge(s), 1.6) * smoothstep(0.0, 0.4, 0.4);
    Flow f = flow(sourceUV(s), edge, t);
    Flow fx = flow(sourceUV(sx), pow(sourceEdge(sx), 1.6), t);
    Flow fy = flow(sourceUV(sy), pow(sourceEdge(sy), 1.6), t);
    float fw = abs(fx.direction - f.direction) + abs(fy.direction - f.direction);

    float bump = f.bump;
    edge = f.edge;
    float2 uv = sourceUV(s);
    const float cycleWidth = 2.0;
    float r1 = 0.12 / cycleWidth * (1.0 - 0.4 * f.bumpEarly), r2 = 0.07 / cycleWidth * (1.0 + 0.4 * f.bumpEarly);
    float3 w = float3(cycleWidth * r1, cycleWidth * r2, 1.0 - r1 - r2);
    w.y -= 0.02 * smoothstep(0.0, 1.0, edge + bump);
    float cd = saturate(1.0 - bump);
    float dR = cd + 0.03 * bump * f.noise
             + 5.0 * (smoothstep(-0.1, 0.2, uv.y) * (1.0 - smoothstep(0.1, 0.5, uv.y))) * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 1.0, bump)))
             - f.d1;
    float dB = cd * 1.3 + (smoothstep(0.0, 0.4, uv.y) * (1.0 - smoothstep(0.1, 0.8, uv.y))) * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 0.8, bump)))
             - 0.2 * edge;
    dR *= 0.015; dB *= 0.015;
    const float soft = 0.005;
    float blur = soft + 0.5 * smoothstep(1.0, 10.0, cycleWidth) * smoothstep(0.0, 1.0, edge);
    float3 c1 = float3(0.98, 0.98, 1.0), c2 = float3(0.1, 0.1, 0.1 + 0.1 * smoothstep(0.7, 1.3, f.d2));
    float3 chrome = float3(colorChanges(c1.r, c2.r, fract(f.direction + dR), w, blur + fw + soft * 0.08, bump),
                           colorChanges(c1.g, c2.g, fract(f.direction), w, blur + fw + soft * 0.05, bump),
                           colorChanges(c1.b, c2.b, fract(f.direction - dB), w, blur + fw, bump));

    // Heat ramp, a splash of green and a hint of cyan on the brightest bands, fringe re-added.
    float lum = dot(chrome, float3(0.2126, 0.7152, 0.0722));
    float3 ramped = ramp4(pow(saturate(lum), 0.85), float3(.32, .03, .02), float3(.80, .13, .03), float3(.96, .48, .04), float3(.98, .86, .30));
    float gb = smoothstep(0.64, 0.8, lum) * (1.0 - smoothstep(0.9, 0.98, lum));
    ramped = mix(ramped, float3(.40, .86, .24), green * gb * 0.9);
    ramped = mix(ramped, float3(.30, .78, .80), green * smoothstep(0.8, 0.9, lum) * (1.0 - smoothstep(0.93, 1.0, lum)) * 0.5);
    float3 metalColor = saturate(ramped + (chrome - lum) * 0.6);

    // Ahead of the metal: the page colour warming into a heat glow, a bright front, glowing seeds.
    float ff = saturate(s.field);
    float3 outside = mix(base, heat(0.25 + (0.35 + 0.25 * green) * ff), saturate(ff * ff * 0.95));
    float3 color = mix(outside, metalColor, cov);
    float front = exp(-(s.field - 1.0) * (s.field - 1.0) * 4.0) * (1.0 - smoothstep(4.0, 7.0, time) * 0.8);
    float seed = exp(-s.q1 * 14.0) * s.g1 + exp(-s.q2 * 14.0) * s.g2;
    color = mix(color, float3(1.0, 0.55, 0.18), saturate(front * 0.45));
    color = mix(color, float3(1.0, 0.84, 0.60), saturate(seed * 0.35));

    // Paper's banding fix.
    color += 1.0 / 256.0 * (fract(sin(dot(0.014 * position, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);
    return color;
}

} // namespace orb

/// Fills the view edge to edge with the twin-source liquid metal, grown out of `base`.
/// `time` is the metal's own clock: the caller slows it to a crawl as the page lands.
[[ stitchable ]] half4 twinMetal(float2 position, half4 color, float2 size, float time, float3 base, float green) {
    return half4(half3(orb::metal(position, size, time, base, green)), 1.0h);
}

/// A soft green pulse rolling out across the page from `origin` when a stop is ticked off.
/// `progress` runs 0 to 1. Premultiplied, so it lays over the page.
[[ stitchable ]] half4 welcomePulse(float2 position, half4 color, float2 size, float2 origin, float progress) {
    float2 d2 = position - origin;
    float d = length(d2);
    float reach = length(size) * 1.05;
    float e = 1.0 - pow(1.0 - progress, 2.2);              // fast out, easing as it spreads
    float r = e * reach;
    float width = 50.0 + 160.0 * e;
    // A gently wavy front, so it reads as light moving rather than a perfect circle.
    float angle = atan2(d2.y, d2.x);
    float wave = 0.5 + 0.5 * sin(angle * 5.0 + progress * 9.0) * sin(angle * 3.0 - progress * 5.0);
    float front = exp(-pow((d - r - 18.0 * (wave - 0.5)) / width, 2.0));
    float wake = (1.0 - smoothstep(0.0, r + 1.0, d)) * 0.35;   // a faint glow left behind the front
    float fade = (1.0 - smoothstep(0.55, 1.0, progress)) * smoothstep(0.0, 0.06, progress);
    float a = (front * (0.26 + 0.1 * wave) + wake * 0.12) * fade;
    float3 g = mix(float3(0.18, 0.80, 0.38), float3(0.62, 0.92, 0.32), wave * 0.6);
    return half4(half3(g * a), half(a));
}
