#version 460 core

// ═══════════════════════════════════════════════════════════════════════
// Aurum Liquid Glass — real iOS 26-style glass shader.
//
// This is what actually separates "blurred tint" from "glass": every
// pixel samples the backdrop from a position that has been BENT by a
// simulated glass surface normal (refraction), split slightly per color
// channel at the edges (chromatic dispersion, like a prism), lit with a
// fresnel rim that brightens toward the silhouette edge, and topped with
// a directional specular glare. None of that exists in a flat
// BackdropFilter blur + gradient overlay — this is the actual optical
// recipe Apple's Liquid Glass material uses.
//
// Inputs (uniforms), in the exact order Dart's setFloat()/
// setImageSampler() must supply them. Index 0 (uSize) and sampler 0
// (uBackdrop) are auto-filled by the engine itself when this shader is
// used via ImageFilter.shader — Dart code never calls setFloat/
// setImageSampler for those two, only for everything after:
//   0: uSize (vec2)   - engine-filled: size of the filtered surface, px
//   1: uRadius         - corner radius in logical px
//   2: uRefraction      - refraction strength (px of max sample offset)
//   3: uChroma          - chromatic dispersion strength (0..1)
//   4: uFresnelPower    - edge glow falloff exponent
//   5: uLightX          - directional light origin x (0..1, surface space)
//   6: uLightY          - directional light origin y (0..1, surface space)
//   7: uTint (vec4)     - base tint color, straight (non-premultiplied)
//                          alpha, composited manually below
//  11: uIsDark          - 1.0 dark theme, 0.0 light theme
// sampler0: uBackdrop (vec2) - engine-filled: the live backdrop pixels
//           behind this widget, already softened by the BackdropFilter
//           blur pass Dart applies in the SAME filter chain before this
//           shader runs — refraction then bends soft frosted light,
//           exactly like real glass, not a sharp double-image.
// ═══════════════════════════════════════════════════════════════════════

#include <flutter/runtime_effect.glsl>

// ImageFilter.shader (the Impeller backdrop-filter path) has a hard
// engine requirement: uniform index 0 MUST be a vec2 (auto-filled by the
// engine with the filtered texture's size), and sampler index 0 MUST be
// the first sampler declared (auto-filled with the backdrop pixels). Both
// must exist even though Dart-side code never sets them explicitly.
uniform vec2 uSize;

uniform float uRadius;
uniform float uRefraction;
uniform float uChroma;
uniform float uFresnelPower;
uniform float uLightX;
uniform float uLightY;
uniform vec4 uTint;
uniform float uIsDark;

uniform sampler2D uBackdrop;

out vec4 fragColor;

// Signed distance to a rounded rect centered at `center`, half-size `he`,
// corner radius `r`. Negative inside, positive outside, 0 at the edge —
// this is what lets us derive a smooth surface NORMAL near the edge
// (the gradient of the SDF), which is the whole basis for refraction:
// real glass bends light more where the surface curves away from flat,
// i.e. right at the rounded edge, and barely at all in the flat middle.
float roundedRectSDF(vec2 p, vec2 he, float r) {
  vec2 d = abs(p) - he + vec2(r);
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  // OpenGL(ES) backend renders custom ImageFilter shaders upside down
  // unless the y-axis is explicitly flipped here — see Flutter's own
  // fragment-shader docs for this exact caveat.
  uv.y = 1.0 - uv.y;
#endif
  vec2 center = uSize * 0.5;
  vec2 p = fragCoord - center;
  vec2 he = uSize * 0.5;

  float dist = roundedRectSDF(p, he, uRadius);

  // Outside the rounded-rect silhouette entirely -> fully transparent.
  // Kept branchless (no `if`/`return`) on purpose: mobile GPUs are
  // tile-based and a fragment shader with a data-dependent early exit
  // still costs a full warp's worth of divergent work in the worst
  // case, so a branchless early-out is actually cheaper here than an
  // `if` would be, not just simpler. `outside` is 0 inside the shape and
  // ramps to 1 just past it; multiplying the final alpha by
  // `(1.0 - outside)` collapses the whole surface to fully transparent
  // there for free, no separate exit path needed.
  float outside = smoothstep(0.0, 1.5, dist);

  // Estimate the local surface normal via the SDF gradient (cheap
  // central-difference — 4 extra SDF evals, negligible cost).
  float eps = 1.0;
  vec2 grad = vec2(
    roundedRectSDF(p + vec2(eps, 0.0), he, uRadius) - roundedRectSDF(p - vec2(eps, 0.0), he, uRadius),
    roundedRectSDF(p + vec2(0.0, eps), he, uRadius) - roundedRectSDF(p - vec2(0.0, eps), he, uRadius)
  );
  vec2 normal = length(grad) > 0.0001 ? normalize(grad) : vec2(0.0);

  // Refraction falls off from the edge inward — strongest right at the
  // rim (where a real glass bevel curves the most), fading to ~0 in the
  // flat interior. `edgeBand` controls how wide that curved bevel reads.
  float edgeBand = 34.0;
  float edgeFactor = 1.0 - smoothstep(-edgeBand, 0.0, dist);
  edgeFactor = clamp(edgeFactor, 0.0, 1.0);
  // Ease the falloff so it feels like a lens bevel, not a linear ramp.
  edgeFactor = edgeFactor * edgeFactor * (3.0 - 2.0 * edgeFactor);

  vec2 refractOffset = normal * uRefraction * edgeFactor;

  // ── Chromatic dispersion ────────────────────────────────────────────
  // Real glass bends different wavelengths by slightly different
  // amounts (that's literally what a prism is). Sampling R/G/B at
  // slightly different offsets along the same refraction direction is
  // the standard, cheap way to fake this convincingly.
  float chroma = uChroma * edgeFactor;
  vec2 uvR = (fragCoord + refractOffset * (1.0 + chroma)) / uSize;
  vec2 uvG = (fragCoord + refractOffset) / uSize;
  vec2 uvB = (fragCoord + refractOffset * (1.0 - chroma)) / uSize;

#ifdef IMPELLER_TARGET_OPENGLES
  uvR.y = 1.0 - uvR.y;
  uvG.y = 1.0 - uvG.y;
  uvB.y = 1.0 - uvB.y;
#endif

  uvR = clamp(uvR, 0.0015, 0.9985);
  uvG = clamp(uvG, 0.0015, 0.9985);
  uvB = clamp(uvB, 0.0015, 0.9985);

  float r = texture(uBackdrop, uvR).r;
  float g = texture(uBackdrop, uvG).g;
  float b = texture(uBackdrop, uvB).b;
  vec3 refracted = vec3(r, g, b);

  // ── Base tint (the glass's own body color/weight) ───────────────────
  vec3 color = mix(refracted, uTint.rgb, uTint.a);

  // ── Fresnel rim ──────────────────────────────────────────────────────
  // Brightens toward the silhouette edge — the classic "light catching
  // the rim of a glass pane" look. Directional: stronger on the side
  // facing the simulated light source, near-absent on the opposite side,
  // which is what makes it read as a lit 3D bevel instead of a flat
  // uniform outline.
  vec2 lightDir = normalize(vec2(uLightX, uLightY) - vec2(0.5));
  float facing = dot(normal, -lightDir) * 0.5 + 0.5;
  float fresnel = pow(edgeFactor, uFresnelPower) * facing;
  color += fresnel * (uIsDark > 0.5 ? 0.35 : 0.55);

  // ── Specular glare streak ────────────────────────────────────────────
  // A soft directional highlight band near the top, offset toward the
  // light — the "shine" that sells a curved glossy surface. Kept subtle
  // and narrow so it reads as a highlight, not a diagonal wipe.
  float specBand = 1.0 - smoothstep(0.0, 0.38, abs(uv.y - (1.0 - uLightY) * 0.28));
  float specSide = 1.0 - smoothstep(0.0, 0.6, abs(uv.x - uLightX));
  float specular = specBand * specSide * (1.0 - edgeFactor * 0.3);
  color += specular * (uIsDark > 0.5 ? 0.10 : 0.16);

  // ── Inner shadow at the very bottom edge ────────────────────────────
  // Real glass isn't uniformly lit — the edge opposite the light sits in
  // faint shadow, which adds the depth/weight a flat panel is missing.
  float shadowFacing = 1.0 - facing;
  float innerShadow = pow(edgeFactor, 2.2) * shadowFacing;
  color -= vec3(uIsDark > 0.5 ? 0.14 : 0.08) * innerShadow;

  // Alpha: fully opaque in the interior (the tint+refraction already
  // carries the backdrop through), soft anti-aliased falloff exactly at
  // the rounded-rect boundary, hard-zeroed past it via `outside`.
  float alpha = (1.0 - smoothstep(-1.0, 1.0, dist)) * (1.0 - outside);

  fragColor = vec4(clamp(color, 0.0, 1.0) * alpha, alpha);
}
