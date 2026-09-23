#version 460 core

// ═══════════════════════════════════════════════════════════════════════
// Aurum Liquid Glass — iOS 26 style, single tuned look.
//
// What makes this read as REAL glass instead of "blurred tint":
//   1. LENS refraction — the backdrop is sampled from a position bent
//      by the surface normal, strongest at the rim, ~0 in the flat
//      middle (a thick glass slab's bevel), with per-channel dispersion.
//   2. ABSORPTION, not overlay — the glass body darkens/lightens the
//      backdrop multiplicatively and only a small amount of neutral
//      body colour is mixed in. Content behind stays visible and keeps
//      its own colour (Apple's glass never looks like a painted panel).
//   3. RIM-FOLLOWING specular — the highlight hugs the silhouette on
//      the light-facing side (top-left) and a weaker counter-glint sits
//      opposite (bottom-right), exactly like a lit bevel. No floating
//      diagonal streak.
//   4. DIRECTIONAL fresnel + thin inner glow so the edge feels like
//      it has thickness.
//
// Uniform contract (Dart setFloat order). uSize (vec2) + sampler
// uBackdrop are engine-filled for ImageFilter.shader:
//   0: uSize (vec2, engine)   1: uRadius
//   2: uRefraction            3: uChroma
//   4: uFresnelPower          5: uLightX      6: uLightY
//   7..10: uTint (vec4: rgb = neutral body colour, a = tint weight)
//  11: uIsDark
//  12: uBevel                 13: uBrightness   14: uSaturation
// (Indices/order intentionally unchanged from the previous shader so
//  Dart-side setFloat calls need no renumbering.)
// ═══════════════════════════════════════════════════════════════════════

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

uniform float uRadius;
uniform float uRefraction;
uniform float uChroma;
uniform float uFresnelPower;
uniform float uLightX;
uniform float uLightY;
uniform vec4 uTint;      // rgb = neutral body colour, a = tint weight
uniform float uIsDark;
uniform float uBevel;
uniform float uBrightness;
uniform float uSaturation;

uniform sampler2D uBackdrop;

out vec4 fragColor;

float roundedRectSDF(vec2 p, vec2 he, float r) {
  vec2 d = abs(p) - he + vec2(r);
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec2 p = fragCoord - uSize * 0.5;
  vec2 he = uSize * 0.5;
  float dark = uIsDark;

  float dist = roundedRectSDF(p, he, uRadius);
  float outside = smoothstep(0.0, 1.5, dist);

  // Surface normal from the SDF gradient.
  float eps = 1.0;
  vec2 grad = vec2(
    roundedRectSDF(p + vec2(eps, 0.0), he, uRadius) -
        roundedRectSDF(p - vec2(eps, 0.0), he, uRadius),
    roundedRectSDF(p + vec2(0.0, eps), he, uRadius) -
        roundedRectSDF(p - vec2(0.0, eps), he, uRadius));
  vec2 normal = length(grad) > 0.0001 ? normalize(grad) : vec2(0.0);

  // ── Lens profile ────────────────────────────────────────────────────
  // `depth` = distance inward from the rim. A convex-lens profile
  // (squared falloff) concentrates bending near the edge and leaves the
  // interior almost undistorted — legible content, glassy rim.
  float depth = clamp(-dist, 0.0, 1000.0);
  float bevelW = min(26.0, min(he.x, he.y) * 0.9);
  float t = clamp(1.0 - depth / bevelW, 0.0, 1.0);
  float lens = t * t * t;                       // sharp near rim
  float soft = t * t * (3.0 - 2.0 * t);          // gentle shoulder

  // Refract INWARD (negative normal) — a real slab pulls the far
  // backdrop toward the rim, which is what gives the "magnified edge".
  vec2 offset = -normal * uRefraction * lens;

  float ch = uChroma * lens;
  vec2 offR = offset * (1.0 + ch);
  vec2 offG = offset;
  vec2 offB = offset * (1.0 - ch);

  vec2 uvR = (fragCoord + offR) / uSize;
  vec2 uvG = (fragCoord + offG) / uSize;
  vec2 uvB = (fragCoord + offB) / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uvR.y = 1.0 - uvR.y;
  uvG.y = 1.0 - uvG.y;
  uvB.y = 1.0 - uvB.y;
#endif
  uvR = clamp(uvR, 0.002, 0.998);
  uvG = clamp(uvG, 0.002, 0.998);
  uvB = clamp(uvB, 0.002, 0.998);

  vec3 bg = vec3(texture(uBackdrop, uvR).r,
                 texture(uBackdrop, uvG).g,
                 texture(uBackdrop, uvB).b);

  // ── Body: absorption first, neutral tint second ─────────────────────
  bg *= uBrightness;
  float luma = dot(bg, vec3(0.2126, 0.7152, 0.0722));
  // Saturate, but pull the boost back for already-saturated pixels so
  // strong colours (red/orange album art) don't clip to a flat 1.0 and
  // read as a colour cast.
  float chromaAmt = max(bg.r, max(bg.g, bg.b)) - min(bg.r, min(bg.g, bg.b));
  float satBoost = 1.0 + (uSaturation - 1.0) * (1.0 - smoothstep(0.35, 0.85, chromaAmt));
  bg = mix(vec3(luma), bg, satBoost);

  // Multiplicative absorption (glass slightly darkens in dark mode /
  // slightly milks in light mode) + a LOW-weight neutral body mix.
  vec3 absorb = dark > 0.5 ? vec3(0.86) : vec3(1.0);
  vec3 body = bg * absorb;
  vec3 color = mix(body, uTint.rgb, uTint.a);

  // Soft milky lift toward the centre-top — the diffuse "sheen" on a
  // frosted slab. Very low amplitude; it's what stops the interior from
  // looking flat without turning into a gradient overlay.
  float sheen = (1.0 - uv.y) * (1.0 - soft) * (dark > 0.5 ? 0.035 : 0.06);
  color += sheen;

  // ── Light direction (from top-left) ─────────────────────────────────
  // Light comes from the top-left; normal points OUTWARD, so the lit
  // rim is the one whose outward normal points up-left. uLightX/Y bias
  // that direction slightly (kept so Dart-side values still matter).
  vec2 toLight = normalize(vec2(-0.6 + (uLightX - 0.5) * 0.4, -0.8 + (uLightY - 0.08) * 0.4));
  float facing = dot(normal, toLight);
  float litSide = max(facing, 0.0);
  float darkSide = max(-facing, 0.0);

  // ── Fresnel rim (directional) ───────────────────────────────────────
  float rimMask = pow(t, uFresnelPower + 1.0);
  color += rimMask * (0.10 + 0.55 * litSide) * (dark > 0.5 ? 0.42 : 0.60);
  color -= rimMask * darkSide * (dark > 0.5 ? 0.10 : 0.05);

  // ── Rim-following specular (the big "real glass" cue) ───────────────
  // Thin ~1.6px ridge hugging the silhouette, bright on the lit side,
  // with a weaker counter-glint on the opposite side.
  float ridge = 1.0 - smoothstep(0.0, 1.7, depth);
  ridge *= (1.0 - outside);
  float specMain = ridge * pow(litSide, 1.4);
  float specCounter = ridge * pow(darkSide, 2.0) * 0.38;
  color += (specMain * (dark > 0.5 ? 0.85 : 0.95) +
            specCounter * (dark > 0.5 ? 0.55 : 0.50)) * uBevel;

  // Inner soft glow just inside the ridge (gives the edge thickness).
  float inner = smoothstep(0.0, 7.0, depth) *
                (1.0 - smoothstep(7.0, 16.0, depth));
  color += inner * litSide * (dark > 0.5 ? 0.06 : 0.09) * uBevel;

  // Subtle inner shadow on the far side — depth without a drop shadow.
  color -= rimMask * darkSide * (dark > 0.5 ? 0.06 : 0.04) * uBevel;

  // Hairline outer rim so the shape reads on any backdrop.
  float hair = (1.0 - smoothstep(0.0, 1.1, depth)) * (1.0 - outside);
  color = mix(color, vec3(dark > 0.5 ? 0.92 : 0.98), hair * 0.16 * uBevel);

  float alpha = (1.0 - smoothstep(-1.0, 1.0, dist)) * (1.0 - outside);
  fragColor = vec4(clamp(color, 0.0, 1.0) * alpha, alpha);
}
