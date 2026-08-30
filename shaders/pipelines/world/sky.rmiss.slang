// Ray miss = sky. Two sky-view LUT fetches (sun slice + moon slice) give the whole atmosphere; the disc
// sprites, the starfield and the night airglow floor are added on top. Everything physical lives in
// sky.slang, shared verbatim with the LUT bakes, so the sky a ray sees and the sky the LUT holds cannot
// diverge.
//
// Atmospheric scattering is amortized into the per-frame LUT. Analytic stars, airglow, and textured
// celestial discs are combined with that physical result here.
//
// The volumetric clouds come from the per-frame dome bake (sky_lut/clouds.comp): one bilinear fetch
// supplies the cloud in-scatter (RGB) and the layer's transmittance (A) along this ray. The atmosphere
// behind the layer is attenuated by that A, stars are occluded by it, and the sun/moon discs are gated
// by the same dome sampled at the body's direction — clouds only ever ATTENUATE, never emit extra light
// toward the discs, so the PAYLOAD_SHOW_CELESTIAL anti-double-count contract is unchanged.
//
// Non-overworld dimensions have no atmosphere: the sky is the attribute probe's per-dimension colour
// scaled by the look package's luminance anchor, the End keeps the starfield, and neither draws a disc.
//
// Celestial discs are gated by a packed payload flag, which raygen sets per-ray from the path state: true
// on the primary ray and after every specular/dielectric bounce (so the sun/moon appear in water, glass
// and metal reflections/refractions), false after a diffuse vertex did sun/moon NEE — otherwise the disc
// would be counted twice against the direct light and show up as fireflies. The atmosphere and the stars
// are added on every miss at any bounce: stars are not a NEE light, so they never double-count.
import world_common;
import sky;
import clouds;
import bindings;

// Vanilla celestials atlas (sun + moon-phase sprites), bound by RtComposite. Sampled with an explicit LOD
// (a miss shader has no derivatives). Keeping the real sprites means a resource pack's sun and moon still
// show up, which a procedural disc would silently drop.
// Drawn disc radiance is derived from illuminance and the solid angle the body is actually DRAWN at
// (L = E / Ω), deliberately not from its true surface luminance. Vanilla's sun quad subtends ~60x the real
// sun, i.e. ~3900x its solid angle; painting it at the physical 1.6e9 cd/m² would put ~3900x the sun's
// power into every path that sees it. Specular and dielectric bounces do see it and have already taken the
// sun through NEE, so that double-count would go from harmless to dominant, with fireflies off every
// glossy lobe. Deriving from illuminance keeps the drawn body's total power equal to the real one's at
// whatever size it is drawn, and costs nothing visually: the result still sits ~15 EV over an 18%-grey
// noon surface, which the ACES 2.0 output transform renders as pure white either way.
float discRadiance(float illuminance, float halfAngle) {
    float solidAngle = 2.0 * SKY_PI * (1.0 - cos(halfAngle));
    return illuminance / max(solidAngle, 1.0e-8);
}

// Dave Hoskins' hash13 (https://www.shadertoy.com/view/4djSRW): well-distributed and pattern-free.
float hash13(float3 p3) {
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

// Rotate v about a unit axis by angle (Rodrigues). Used to wheel the starfield about the celestial pole.
float3 rotateAxis(float3 v, float3 axis, float ang) {
    float c = cos(ang), s = sin(ang);
    return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

// Procedural starfield, a faithful port of vanilla's buildStars(): ~1500 discrete stars at random sphere
// directions, each a small SQUARE billboard of random size and rotation. A cube-map grid is the spatial
// accelerator — at most one star per cell, at a hashed position inset from the cell edges (so its square
// never crosses into a neighbour), drawn as a hash-rotated square of hashed size. The lookup direction is
// rotated about the celestial pole by -starAngle so the field wheels with world time like the real sky.
static const float STAR_CELLS     = 21.0;  // cube-face grid resolution; with the threshold gives ~1500 stars
static const float STAR_THRESHOLD = 0.86;  // cell occupancy cutoff (higher = fewer stars)
static const float STAR_HALF      = 0.045; // star half-size as a fraction of a cell (≈ vanilla 0.11° at centre)
float3 stars(float3 dir, SkyState state, float3 extinction) {
    if (state.starLuminance <= 0.0 || dir.y <= 0.0) {
        return float3(0.0);
    }
    // Negative angle: rotating the LOOKUP direction is the inverse of rotating star geometry, so
    // -starAngle makes the field wheel the SAME way the sun and moon do.
    float3 sdir = rotateAxis(dir, normalize(celestialAxis(state.noonTilt)), -state.starAngle);
    // Cube-map face + 2D gnomonic uv → uniform square cells, no pole/equator distortion.
    float3 a = abs(sdir);
    float2 uv;
    float face;
    if (a.x >= a.y && a.x >= a.z)      { uv = sdir.yz / a.x; face = sdir.x > 0.0 ? 0.0 : 1.0; }
    else if (a.y >= a.z)               { uv = sdir.xz / a.y; face = sdir.y > 0.0 ? 2.0 : 3.0; }
    else                               { uv = sdir.xy / a.z; face = sdir.z > 0.0 ? 4.0 : 5.0; }
    float2 g = uv * STAR_CELLS;
    float3 id = float3(floor(g), face);
    if (hash13(id) < STAR_THRESHOLD) {
        return float3(0.0); // no star in this cell
    }
    float sz = STAR_HALF * (0.6 + 0.8 * hash13(id + 53.0));
    float inset = sz * 1.5; // keeps the rotated square clear of the cell edge
    float2 center = inset + (1.0 - 2.0 * inset) * float2(hash13(id + 11.0), hash13(id + 23.0));
    float2 q = frac(g) - center;
    float ang = hash13(id + 91.0) * 6.2831853;            // random per-star rotation (vanilla zRot)
    float cs = cos(ang), sn = sin(ang);
    q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y); // GLSL mat2(cs,-sn,sn,cs) * q, written out
    float box = max(abs(q.x), abs(q.y));                  // Chebyshev distance → square
    float star = 1.0 - smoothstep(sz * 0.6, sz, box);     // soft-edged square (helps DLSS stability)
    if (star <= 0.0) {
        return float3(0.0);
    }
    float bright = 0.55 + 0.45 * hash13(id + 71.0);       // mild per-star brightness variation
    // Per-star colour temperature: a hash picks a spot on a warm-orange to blue-white ramp, matching real
    // star populations. Extinction reddens and dims them toward the horizon on the atmosphere's curve.
    float3 starColor = lerp(float3(0.78, 0.60, 0.42), float3(0.50, 0.62, 0.95), hash13(id + 137.0));
    return star * bright * starColor * state.starLuminance * extinction;
}

/** Atmosphere in-scatter for a world direction: both bodies' slices of this frame's sky-view LUT. */
float3 skyDome(float3 dir, SkyState state) {
    float2 sunUv = skyViewLutUv(state.viewerRadiusKm, dir.y,
            lightViewCosine(dir, state.sunDir), SKY_VIEW_BODY_SUN);
    float2 moonUv = skyViewLutUv(state.viewerRadiusKm, dir.y,
            lightViewCosine(dir, state.moonDir), SKY_VIEW_BODY_MOON);
    return skyViewLut.SampleLevel(sunUv, 0.0).rgb + skyViewLut.SampleLevel(moonUv, 0.0).rgb;
}

// Overcast grey (linear BT.709) added to the sky by rain, and the whiter flash tint lightning adds.
static const float3 OVERCAST_GREY = float3(0.62, 0.66, 0.74);
static const float3 FLASH_GREY = float3(0.78, 0.80, 0.86);

// Cloud transmittance toward a celestial body, averaged over a few taps of the dome across the DRAWN
// disc's angular size. The drawn quad spans ~17 degrees, far wider than one dome texel, so a single
// sample could hide the whole disc behind a thin cloud edge; the average keeps the occlusion soft at the
// disc's own scale.
float celestialCloudTransmittance(SkyState state, float3 bodyDir, float halfAngle) {
    float3 right;
    float3 up;
    celestialSquareFrame(bodyDir, right, up);
    float k = tan(halfAngle) * 0.45;
    float t = cloudDomeLut.SampleLevel(cloudDomeUv(bodyDir), 0.0).a;
    t += cloudDomeLut.SampleLevel(cloudDomeUv(normalize(bodyDir + right * k)), 0.0).a;
    t += cloudDomeLut.SampleLevel(cloudDomeUv(normalize(bodyDir - right * k)), 0.0).a;
    t += cloudDomeLut.SampleLevel(cloudDomeUv(normalize(bodyDir + up * k)), 0.0).a;
    t += cloudDomeLut.SampleLevel(cloudDomeUv(normalize(bodyDir - up * k)), 0.0).a;
    return t / 5.0;
}

[shader("miss")]
void main(inout Payload payload) {
    WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    SkyState state = skyState(worldPush);
    float3 dir = normalize(WorldRayDirection());
    bool showCelestial = (payload.flags & PAYLOAD_SHOW_CELESTIAL) != 0u;

    float3 color;
    if (state.dimension == DIMENSION_OVERWORLD) {
        // Sample the volumetric cloud dome (RGB = in-scattered radiance, A = transmittance).
        float4 cloudDome = cloudDomeLut.SampleLevel(cloudDomeUv(dir), 0.0);
        float baseT = cloudDome.a;
        float3 baseColor = cloudDome.rgb;

        float alt = state.cloudAltRebased;

        // 4K Ray-rate edge re-contouring & high-frequency micro-erosion
        // Ray-rate edge re-contouring is only used for side/top silhouettes. When the camera is below the
        // cumulus layer, the entry point for every upward ray lies on the flat cloud base; perturbing the
        // baked transmittance with a fresh 3D-noise sample at that entry plane creates a view-centred dark
        // cone that follows the player instead of a stable cloud feature.
        float tEnter, tExit;
        bool undersideView = worldPush.camOffset.y < alt && dir.y > 0.0;
        float edgeWeight = smoothstep(0.01, 0.15, baseT) * (1.0 - smoothstep(0.85, 0.99, baseT));
        if (!undersideView && edgeWeight > 0.0
                && intersectCloudLayer(worldPush.camOffset.xyz, dir, alt, alt + CLOUD_THICKNESS_BLOCKS, tEnter, tExit)) {
            float3 pEnter = worldPush.camOffset.xyz + dir * tEnter + float3(worldPush.waterAnchor.x, 0.0, worldPush.waterAnchor.y);
            float erosion = cloudErosionNoise3D(cloudShapeNoise, pEnter * 0.0035);
            baseT = saturate(baseT + (erosion - 0.5) * 0.25 * edgeWeight);
        }

        // 4K Native high-altitude cirrus evaluation (fine crystal fibers)
        float cirrusAlt = alt + CIRRUS_ALT_OFFSET + CIRRUS_THICKNESS * 0.5;
        // Base atmosphere in-scatter feeds both the cirrus ambient term and the sky composition below;
        // sun-direction extinction feeds both the cirrus tint and the drawn sun disc. Fetch each once —
        // skyDome is 2 LUT taps + 2 skyViewLutUv (acos pair), sunExtinction another LUT tap — rather
        // than recomputing them per consumer.
        float3 dome = skyDome(dir, state);
        bool cirrusRay = dir.y > 0.015 && worldPush.camOffset.y < cirrusAlt && baseT > 0.05;
        float3 sunExtinction = float3(0.0);
        if (cirrusRay || showCelestial) {
            sunExtinction = transmittanceToSpace(transmittanceLut, state.viewerRadiusKm,
                    state.sunDir, state.sunAngularRadius);
        }
        if (cirrusRay) {
            float tCirrus = (cirrusAlt - worldPush.camOffset.y) / dir.y;
            if (tCirrus < 30000.0) {
                float3 pCirrus = worldPush.camOffset.xyz + dir * tCirrus;
                float cirrusDensity = highCloudDensityAt(pCirrus, worldPush.waterAnchor.xy, alt,
                        state.cloudCoverage, state.cloudTime, cloudShapeNoise, cloudCurlNoise);
                if (cirrusDensity > 0.0) {
                    float cirrusT = exp(-cirrusDensity * 0.30);
                    float3 lightColor = float3(state.sunIlluminance) * sunExtinction;
                    float3 cirrusLit = lightColor * (cloudPhase(dot(dir, state.sunDir)) * 0.85 + 0.15) + dome * 0.65;
                    float3 cirrusScatter = cirrusLit * (1.0 - cirrusT);
                    baseColor += baseT * cirrusScatter;
                    baseT *= cirrusT;
                }
            }
        }

        float3 cloudT = float3(baseT);
        float3 cloudColor = baseColor;
        color = dome * cloudT + cloudColor;
        // Airglow plus integrated unresolved starlight: the real floor of a moonless night sky (~1e-3
        // cd/m²), isotropic because it is emitted by the upper atmosphere itself rather than scattered
        // from a body. Multiple scattering is in the LUT, so this remains a flat, physically small
        // constant.
        color += state.airglowLuminance;
        // Weather: rain lifts the sky toward a flat overcast grey; a lightning flash does the same
        // briefly in a whiter tint. Both sit on top of the physical sky so terrain (via miss rays) and
        // the dome stay one consistent ambient. The grey is lit by the celestial bodies like the clouds
        // are, so a rainy night stays dark instead of glowing at the daylight grey level.
        float greyLit = saturate(state.sunIlluminance / 128000.0 + state.moonIlluminance * 0.01);
        color += OVERCAST_GREY * state.rain * state.weatherGreyLum * greyLit;
        color += FLASH_GREY * state.flash * state.weatherGreyLum;

        // Extinction along the view ray: stars redden and dim into the horizon on exactly the curve the
        // sky itself follows, because it is the same LUT that produced the sky. Zero angular radius — a
        // star is a point, so it sets at the horizon line. Clouds occlude stars with the same dome
        // transmittance that attenuates the atmosphere.
        float3 extinction = transmittanceToSpace(transmittanceLut, state.viewerRadiusKm, dir, 0.0);
        color += stars(dir, state, extinction) * cloudT;

        if (showCelestial) {
            float sunCos = dot(dir, state.sunDir);
            float sunCloudT = celestialCloudTransmittance(state, state.sunDir, 0.015);

            // ---- Realistic Circular Sun Disc, Solar Limb Darkening, Corona & Lens Flare
            if (sunCos > 0.0 && sunCloudT > 1.0e-4) {
                float sunAngle = acos(clamp(sunCos, -1.0, 1.0));
                float sunRadius = 0.016; // Angular radius (~0.92 deg)
                float sunRho = sunAngle / sunRadius;

                float3 directSun = float3(0.0);
                // 1. Sun disc with physical limb darkening (Hestroffer & Magnan)
                if (sunRho <= 1.0) {
                    float mu = sqrt(max(0.0, 1.0 - sunRho * sunRho));
                    float limb = 1.0 - 0.60 * (1.0 - mu);
                    float edgeAA = smoothstep(1.0, 0.94, sunRho);
                    float baseRad = discRadiance(state.sunIlluminance, sunRadius);
                    directSun += float3(baseRad * limb * edgeAA);
                }

                // 2. High-energy forward solar corona
                float corona = 0.06 / (pow(max(sunRho - 0.88, 0.03), 1.5) + 0.04);
                corona *= smoothstep(16.0, 1.0, sunRho);
                directSun += float3(state.sunIlluminance * 0.06 * corona);

                // 3. 8-blade aperture diffraction starburst spikes
                float3 sRight, sUp;
                celestialSquareFrame(state.sunDir, sRight, sUp);
                float2 sLocal = float2(dot(dir, sRight), dot(dir, sUp)) / tan(sunRadius);
                float sTheta = atan2(sLocal.y, sLocal.x);
                float starburst = (pow(abs(cos(sTheta * 4.0)), 16.0) * 0.12 + pow(abs(sin(sTheta * 4.0)), 16.0) * 0.06);
                starburst *= smoothstep(10.0, 1.0, sunRho) * smoothstep(0.4, 1.2, sunRho);
                directSun += float3(state.sunIlluminance * starburst * 0.06);

                color += directSun * sunExtinction * sunCloudT;
            }

            // ---- Optical Lens Flare Ring and Wide Atmospheric Halo
            if (sunCos > 0.60 && sunCloudT > 1.0e-4) {
                float sunDist = acos(clamp(sunCos, -1.0, 1.0));
                // Primary optical 22-degree atmospheric halo ring
                float ring = exp(-pow((sunDist - 0.38) * 14.0, 2.0)) * 0.022;
                // Secondary 46-degree chromatic flare ring
                float ring2 = exp(-pow((sunDist - 0.72) * 18.0, 2.0)) * 0.008;
                float3 flareTint = float3(ring * 1.0 + ring2 * 0.6, ring * 0.92 + ring2 * 0.75, ring * 0.75 + ring2 * 0.95);
                // Broad camera lens glow
                float wideGlow = 0.006 / (sunDist * sunDist + 0.06);
                color += (flareTint + float3(wideGlow)) * state.sunIlluminance * 0.0025 * sunExtinction * sunCloudT;
            }

            // ---- Realistic 3D Spherical Moon with Physical Phase Terminator & Craters
            float moonCos = dot(dir, state.moonDir);
            float moonCloudT = celestialCloudTransmittance(state, state.moonDir, 0.016);
            if (moonCos > 0.0 && moonCloudT > 1.0e-4) {
                float moonAngle = acos(clamp(moonCos, -1.0, 1.0));
                float moonRadius = 0.018; // Angular radius (~1.03 deg)
                float moonRho = moonAngle / moonRadius;

                if (moonRho <= 1.0) {
                    float3 mRight, mUp;
                    celestialSquareFrame(state.moonDir, mRight, mUp);
                    float3 planar = dir / max(moonCos, 1.0e-3);
                    float2 mLocal = float2(dot(planar, mRight), dot(planar, mUp)) / tan(moonRadius);

                    float r2 = dot(mLocal, mLocal);
                    if (r2 <= 1.0) {
                        float nz = sqrt(max(0.0, 1.0 - r2));
                        float3 moonNormal = normalize(mRight * mLocal.x + mUp * mLocal.y + state.moonDir * nz);

                        // 3D Physical phase terminator illuminated by the Sun
                        float NdotL = dot(moonNormal, state.sunDir);
                        float phaseTerminator = smoothstep(-0.05, 0.15, NdotL);

                        // Procedural lunar maria & crater textures
                        float craters = hash13(float3(floor(mLocal * 28.0), 19.0)) * 0.18 + 0.82;
                        float maria = smoothstep(0.25, 0.75, hash13(float3(floor(mLocal * 7.0), 43.0))) * 0.28;
                        float albedo = saturate(craters - maria);

                        // Subtle Earthshine on the dark side of the moon
                        float earthshine = 0.015 * (1.0 - phaseTerminator);

                        float limbAA = smoothstep(1.0, 0.94, moonRho);
                        float moonRad = discRadiance(state.moonIlluminance, moonRadius);
                        float3 moonColor = float3(moonRad * (phaseTerminator * albedo + earthshine) * limbAA);

                        float3 moonExtinction = transmittanceToSpace(transmittanceLut, state.viewerRadiusKm,
                                state.moonDir, state.moonAngularRadius);
                        color += moonColor * moonExtinction * moonCloudT;
                    }
                }
            }
        }
    } else {
        // No atmosphere outside the overworld: the probe's per-dimension sky colour, scaled to radiance
        // by the look package's anchor. The End keeps the starfield (vanilla draws its sky texture and
        // stars); the Nether has neither.
        color = state.vanillaSkyColor * state.skyLuminanceCdM2;
        if (state.dimension == DIMENSION_END && state.starLuminance > 0.0) {
            color += stars(dir, state, float3(1.0));
        }
    }

    // The sky goes out in absolute scene units at full fp32 — packSky writes the payload's three surface
    // words as raw floats rather than halves, which is why the sun disc's ~1e5 cd/m² needs neither a
    // pre-exposure scale nor a clamp to stay representable. The fp16 ceiling reappears only at world.rgen's
    // outImage store, where the finite-half clamp is applied. packSky also
    // overwrites the normal view, so there is no separate normal clear below.
    packSky(payload, bt709ToAcesCg(max(color, float3(0.0))));
    payload.hitT = -1.0;
    payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
    payload.f0 = half3(0.0h, 0.0h, 0.0h);
    payload.flags = 0u;
    payload.roughMetal = packHalf2(float2(1.0, 0.0));
    payload.emissionSss = packHalf2(float2(0.0, 0.0));
    payload.iorTransmission = packHalf2(float2(1.0, 0.0));
    payload.rayCone = 0u;
}
