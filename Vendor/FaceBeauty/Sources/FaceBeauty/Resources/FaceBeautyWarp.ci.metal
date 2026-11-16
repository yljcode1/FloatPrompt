#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Signed radial warp: strength > 0 magnifies (bump), < 0 pinches inward (slim).
// radius 0 is a no-op, so a disabled region contributes nothing. PASS-THROUGH:
// the caller supplies the signed strength — no negation happens in here (a
// previous version negated internally AND the caller negated, so nose/face
// slims bulged on the Metal path).
static inline float2 radialWarp(float2 p, float2 c, float radius, float strength) {
    if (radius <= 0.0f || strength == 0.0f) return p;
    float2 d = p - c;
    float dist = length(d);
    if (dist >= radius) return p;
    float t = dist / radius;
    float falloff = smoothstep(1.0f, 0.0f, t);
    float factor = 1.0f - strength * falloff;
    return c + d * factor;
}

// Four independent radial regions (face, nose, left eye, right eye) as one
// inverse-warp pass. Inverse order of the forward chain (eyes → nose → face),
// so the composition matches the Core Image fallback.
extern "C" float2 beautyWarp(
    float2 c0, float r0, float s0,   // face
    float2 c1, float r1, float s1,   // nose
    float2 c2, float r2, float s2,   // left eye
    float2 c3, float r3, float s3,   // right eye
    coreimage::destination dest)
{
    float2 p = dest.coord();
    p = radialWarp(p, c0, r0, s0);
    p = radialWarp(p, c1, r1, s1);
    p = radialWarp(p, c2, r2, s2);
    p = radialWarp(p, c3, r3, s3);
    return p;
}
