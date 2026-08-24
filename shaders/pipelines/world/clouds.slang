// Volumetric cloud model shared by every consumer of clouds:
//
//   * sky_lut/clouds.comp marches this field into a per-frame low-resolution dome (colour + transmittance)
//     so no radiance ray ever marches clouds itself;
//   * lighting.slang evaluates cloudTransmittanceToward() on celestial shadow rays that reached the sky,
//     which is how cloud shadows land on terrain and how clouds dim the sun/moon NEE term;
//   * sky.rmiss samples the baked dome at the sun/moon direction to occlude the drawn discs, and
//     recontours the dome's blurred silhouette with this field; primary writes the cloud motion into the
//     sky guide so DLSS-RR reprojects moving clouds.
//
// One density field, one set of layer constants: the bake and the shadow path can never disagree.
//
// The density recipe follows the production volumetric-cloud model the sky_lut/noise3d.comp volumes were
// baked for: 2D coverage noise shaped by a vertical fade/erosion profile, billow erosion against the
// shape-noise volume, a divergence-free curl warp, two octaves of erosion-noise edge detail, and a
// contrast remap that pushes the field toward binary — that last step is what keeps cloud edges crisp
// instead of fbm-soft.
//
// All positions are REBASED blocks (the trace's own space). The horizontal domain is rebuilt as
// rebasedPos.xz + worldPush.waterAnchor.xy, which is invariant under the terrain's per-move rebase for
// exactly the same reason the water wave domain is; the layer altitude is pushed already rebased.
//
// The field is advected by a constant wind in world space. Cloud motion per frame is wind * the pushed
// frame delta, so the sky guide's motion vector and the field's own movement stay in lock-step.

import world_common;
import sky;

// Layer geometry, in blocks. The bottom altitude is per-frame state (vanilla's cloud height attribute,
// pushed rebased); the thickness and density are authored constants of the model.
public static const float CLOUD_THICKNESS_BLOCKS = 320.0;
// Extinction per block at full density. Tuned so a fully dense cloud reads as opaque across the layer.
public static const float CLOUD_DENSITY = 0.045;
// Wind speed in blocks per second. Kept slow: DLSS-RR tracks the sky through the pushed motion vector,
// and a fast drift exceeds what its temporal reprojection can hold without smearing.
public static const float CLOUD_WIND_SPEED = 2.5;
// Horizontal domain scale (1 / base-feature wavelength in blocks).
public static const float CLOUD_SCALE = 0.00045;

// High-altitude Cirrus layer (Layer 1)
public static const float CIRRUS_ALT_OFFSET = 3500.0;
public static const float CIRRUS_THICKNESS = 400.0;
public static const float CIRRUS_DENSITY = 0.005;

// Normalized wind direction (world XZ), precomputed so it can be a static constant.
public static const float2 CLOUD_WIND_DIR = float2(0.94386, 0.33035);

// Maximum ray distance traversed inside the volumetric cloud layer.
public static const float CLOUD_MAX_RAY_DIST = 4000.0;

// Solve the intersection with a spherical altitude surface in the camera's local tangent frame.
//
// Do not form |ro|² - radius² or the small root as -b + sqrt(discriminant). At Earth scale both
// operations subtract nearly equal ~4e13 / ~6e6 float values. The resulting direction-dependent
// quantisation was the dark saddle/cone visible around the zenith when viewing a cloud base from below.
// Factoring c preserves the altitude difference, and Vieta's product gives the small root without the
// second cancellation.
bool cloudAltitudeSphereRoots(float viewerAlt, float dirY, float layerAlt,
                              out float tNear, out float tFar) {
    float planetRad = ATMOS_BOTTOM_KM * 1000.0;
    float b = (planetRad + viewerAlt) * dirY;
    float c = (viewerAlt - layerAlt) * (2.0 * planetRad + viewerAlt + layerAlt);
    float discriminant = b * b - c;
    if (discriminant < 0.0) {
        tNear = -1.0;
        tFar = -1.0;
        return false;
    }

    float root = sqrt(discriminant);
    float q = -b - (b >= 0.0 ? root : -root);
    float r0;
    float r1;
    if (abs(q) > 1.0e-6) {
        r0 = q;
        r1 = c / q;
    } else {
        // The double root at a tangent is -b. Keeping this explicit also avoids 0 / 0.
        r0 = -b;
        r1 = -b;
    }
    tNear = min(r0, r1);
    tFar = max(r0, r1);
    return true;
}

// Spherical atmospheric layer intersection accounting for Earth curvature and camera altitude.
public bool intersectCloudLayer(float3 origin, float3 dir, float bottomAlt, float topAlt, out float tEnter, out float tExit) {
    float tTopNear;
    float tTopFar;
    if (!cloudAltitudeSphereRoots(origin.y, dir.y, topAlt, tTopNear, tTopFar)) {
        tEnter = 0.0;
        tExit = 0.0;
        return false;
    }

    float tBotNear;
    float tBotFar;
    bool hitsBottom = cloudAltitudeSphereRoots(origin.y, dir.y, bottomAlt, tBotNear, tBotFar);

    if (origin.y < bottomAlt) {
        // Viewer is strictly below the cloud layer.
        if (hitsBottom && tBotFar > 0.0) {
            tEnter = max(tBotFar, 0.0);
            tExit = min(tTopFar, tEnter + CLOUD_MAX_RAY_DIST);
        } else if (tTopFar > 0.0 && dir.y > 0.0) {
            tEnter = max(tTopNear, 0.0);
            tExit = min(tTopFar, tEnter + CLOUD_MAX_RAY_DIST);
        } else {
            tEnter = 0.0;
            tExit = 0.0;
            return false;
        }
    } else if (origin.y > topAlt) {
        // Viewer is strictly above the cloud layer.
        if (tTopNear > 0.0) {
            tEnter = max(tTopNear, 0.0);
            float naturalExit = (hitsBottom && tBotNear > 0.0) ? tBotNear : tTopFar;
            tExit = min(naturalExit, tEnter + CLOUD_MAX_RAY_DIST);
        } else {
            tEnter = 0.0;
            tExit = 0.0;
            return false;
        }
    } else {
        // Viewer is INSIDE the cloud layer (bottomAlt <= origin.y <= topAlt).
        tEnter = 0.0;
        float naturalExit = (hitsBottom && tBotNear > 0.0) ? tBotNear : tTopFar;
        tExit = min(naturalExit, tEnter + CLOUD_MAX_RAY_DIST);
    }

    return tExit > tEnter;
}

// Sample the baked shape (R) and erosion (G) volumes; the samplers REPEAT, so these need no fract().
public float cloudShapeNoise3D(Sampler3D noise, float3 p) {
    return noise.SampleLevel(p, 0.0).x;
}

public float cloudErosionNoise3D(Sampler3D noise, float3 p) {
    return noise.SampleLevel(p, 0.0).y;
}

// Curl warp volume, reconstructed to [-1,1].
public float3 cloudCurl3D(Sampler3D curl, float3 p) {
    return curl.SampleLevel(p, 0.0).xyz * 2.0 - 1.0;
}

// ---- Layer 0: Low-altitude dense 3D Cumulus clouds
public float cloudDensityAt(float3 rebasedPos, float2 anchor, float cloudAlt, float coverage, float time,
                     Sampler3D shapeNoise, Sampler3D curlNoise) {
    float altitude = rebasedPos.y;
    float v = (altitude - cloudAlt) / CLOUD_THICKNESS_BLOCKS;
    if (v <= 0.0 || v >= 1.0) {
        return 0.0;
    }

    // Vertical fade/erosion profile: flat bottom base, soft billowy top
    float fadeLow = smoothstep(0.0, 0.12, v);
    float fadeHigh = 1.0 - smoothstep(0.70, 1.0, v);
    float erodeLow = (1.0 - smoothstep(0.0, 0.18, v)) * 0.20;
    float erodeHigh = smoothstep(0.35, 1.0, v) * 0.35;

    // World-stable horizontal domain, advected by the wind. One period spans 1/CLOUD_SCALE blocks.
    float2 xz = rebasedPos.xz + anchor;
    float2 windXz = CLOUD_WIND_DIR * (time * CLOUD_WIND_SPEED);
    float2 domainXz = xz * CLOUD_SCALE + windXz * CLOUD_SCALE;

    // Macro coverage sampled smoothly from the trilinear 3D volume: forms distinct separated cloud banks
    float coverNoise = cloudShapeNoise3D(shapeNoise, float3(domainXz * 0.4, 0.15));
    float bias = 0.98 - 0.65 * coverage;
    float cover = saturate((coverNoise - bias) / max(1.0 - bias, 0.05));
    cover = saturate(cover * fadeLow * fadeHigh - erodeLow - erodeHigh);
    if (cover <= 1.0e-5) {
        return 0.0;
    }

    // 3D Domain for billow carving & erosion
    float3 domain = float3(domainXz, (altitude - cloudAlt) * (CLOUD_SCALE * 2.5));
    float wfade = 1.0 - smoothstep(0.0, 0.35, v) * 0.5;
    float3 curl = cloudCurl3D(curlNoise, domain * 1.5) * wfade;

    // Billow shape carving
    float shapeSample = cloudShapeNoise3D(shapeNoise, domain * 2.0 + curl * 0.12);
    float shape = cover - (1.0 - shapeSample) * 0.35;
    if (shape <= 0.0) {
        return 0.0;
    }

    // Fine erosion detail from the high-frequency volume
    float erosionSample = cloudErosionNoise3D(shapeNoise, (domain + curl * 0.08) * 5.0);
    shape -= (1.0 - erosionSample) * 0.18 * (1.0 - v * 0.35);
    if (shape <= 0.0) {
        return 0.0;
    }

    // Solid core and puffy top
    shape = saturate(shape * 1.6);

    // Vertical density profile: flat base and soft puff top
    float dfade = smoothstep(0.0, 0.10, v) * (1.0 - smoothstep(0.70, 1.0, v));
    return shape * dfade;
}

// ---- Layer 1: High Cloud Family (Cirrus, Cirrocumulus, Cirrostratus)
float hash21Cirrus(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float noise2DCirrus(float2 p) {
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(lerp(hash21Cirrus(i + float2(0.0, 0.0)),
                     hash21Cirrus(i + float2(1.0, 0.0)), u.x),
                lerp(hash21Cirrus(i + float2(0.0, 1.0)),
                     hash21Cirrus(i + float2(1.0, 1.0)), u.x), u.y);
}

float cirrusFbm(float2 p) {
    float2x2 rot = float2x2(0.8, -0.6, 0.6, 0.8);
    float f = 0.0;
    float amp = 0.5;
    float2 coord = p;
    for (int i = 0; i < 4; i++) {
        f += amp * noise2DCirrus(coord);
        coord = mul(rot, coord) * 2.05 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return f;
}

public float highCloudDensityAt(float3 rebasedPos, float2 anchor, float cloudAlt, float coverage, float time,
                                Sampler3D shapeNoise, Sampler3D curlNoise) {
    float altitude = rebasedPos.y;
    float alt = cloudAlt + CIRRUS_ALT_OFFSET;
    float v = (altitude - alt) / CIRRUS_THICKNESS;
    if (v <= 0.0 || v >= 1.0) {
        return 0.0;
    }

    float2 xz = rebasedPos.xz + anchor;
    float2 windXz = CLOUD_WIND_DIR * (time * CLOUD_WIND_SPEED * 1.8);
    
    // Scale: broad atmospheric domain (~3500m per feature)
    float2 p = (xz + windXz) * 0.00028;
    // Anisotropic stretch along wind direction to create realistic mare's tail cirrus fibers
    float2 stretchP = float2(dot(p, CLOUD_WIND_DIR) * 0.35, dot(p, float2(-CLOUD_WIND_DIR.y, CLOUD_WIND_DIR.x)) * 1.2);

    float fbm = cirrusFbm(stretchP);
    
    // Coverage threshold: controls density and separation
    float bias = 0.52 - coverage * 0.25;
    float cirrus = saturate((fbm - bias) / max(1.0 - bias, 0.05));
    if (cirrus <= 1.0e-4) {
        return 0.0;
    }

    // Gentle micro-detail from 3D erosion noise
    float micro = cloudErosionNoise3D(shapeNoise, float3(p * 2.5, 0.5));
    cirrus = saturate(cirrus * (micro * 0.5 + 0.75));

    // Vertical fade: smooth bell curve across layer thickness
    float vFade = smoothstep(0.0, 0.3, v) * (1.0 - smoothstep(0.7, 1.0, v));
    return saturate(cirrus * vFade * 0.5);
}

/**
 * Beer-Lambert transmittance through the cloud layer from {@code origin} toward {@code dir}, evaluated
 * at the segment's midpoint — the analytic counterpart of the bake's raymarch for shadow rays.
 */
public float cloudTransmittanceToward(float3 origin, float3 dir, float2 anchor, float cloudAlt,
                               float coverage, float time, Sampler3D shapeNoise, Sampler3D curlNoise) {
    if (coverage <= 0.0 || dir.y <= 0.002) {
        return 1.0;
    }
    float tEnter;
    float tExit;
    if (!intersectCloudLayer(origin, dir, cloudAlt, cloudAlt + CLOUD_THICKNESS_BLOCKS, tEnter, tExit)) {
        return 1.0;
    }
    float lengthInLayer = tExit - tEnter;
    float3 mid = origin + dir * ((tEnter + tExit) * 0.5);
    float density = cloudDensityAt(mid, anchor, cloudAlt, coverage, time, shapeNoise, curlNoise);
    return exp(-density * CLOUD_DENSITY * lengthInLayer);
}

/**
 * Evaluates cloud transmittance along a finite segment [origin, origin + dir * maxT].
 * Returns 1.0 if the segment does not intersect the cloud layer or if coverage is zero.
 */
public float cloudSegmentTransmittance(float3 origin, float3 dir, float maxT, float2 anchor, float cloudAlt,
                                float coverage, float time, Sampler3D shapeNoise, Sampler3D curlNoise,
                                out float tEnter, out float tExit, out float segLen) {
    tEnter = 0.0;
    tExit = 0.0;
    segLen = 0.0;
    if (coverage <= 0.0 || maxT <= 0.0) {
        return 1.0;
    }
    if (!intersectCloudLayer(origin, dir, cloudAlt, cloudAlt + CLOUD_THICKNESS_BLOCKS, tEnter, tExit)) {
        return 1.0;
    }
    float segEnter = max(tEnter, 0.0);
    float segExit = min(tExit, maxT);
    if (segExit <= segEnter) {
        return 1.0;
    }
    segLen = segExit - segEnter;
    float3 p0 = origin + dir * (segEnter + segLen * 0.25);
    float3 p1 = origin + dir * (segEnter + segLen * 0.75);
    float d0 = cloudDensityAt(p0, anchor, cloudAlt, coverage, time, shapeNoise, curlNoise);
    float d1 = cloudDensityAt(p1, anchor, cloudAlt, coverage, time, shapeNoise, curlNoise);
    float dAvg = 0.5 * (d0 + d1);
    return exp(-dAvg * CLOUD_DENSITY * segLen);
}

/**
 * Dual-paraboloid hemispherical projection:
 * Left square (uv.x in [0, 0.5]): upper sky dome (dy >= 0).
 * Right square (uv.x in [0.5, 1.0]): lower ground hemisphere (dy < 0).
 *
 * The previous orthographic projection reconstructed y as sqrt(1 - r²). Its derivative becomes
 * infinite at r=1, so adjacent dome texels represented sharply different elevations at the horizon.
 * Independent march jitter then exposed those texels as vertical stripes. Dual paraboloid uses
 * y=(1-r²)/(1+r²), which has a finite derivative at both the pole and horizon.
 */
public float2 cloudDomeUv(float3 dir) {
    float2 p = dir.xz / max(1.0 + abs(dir.y), 1.0e-6);
    float2 local = clamp(p * 0.49 + 0.5, 0.005, 0.995);
    return dir.y >= 0.0
            ? float2(local.x * 0.5, local.y)
            : float2(0.5 + local.x * 0.5, local.y);
}

public float3 cloudDomeDir(float2 uv) {
    bool upper = uv.x < 0.5;
    float2 local = upper
            ? float2(uv.x * 2.0, uv.y)
            : float2((uv.x - 0.5) * 2.0, uv.y);
    float2 p = (local - 0.5) / 0.49;
    float r2 = dot(p, p);

    // Do not clamp the square's pixels outside the unit disc onto r=1. Doing so makes every pixel in
    // the four corners another independently marched horizon ray. The whole outside region then acts
    // as a noisy, many-to-one horizon border and leaks vertical bars through bilinear filtering.
    // Dual-paraboloid naturally continues through r=1 into the opposite hemisphere, giving the valid
    // disc a smooth guard band instead.
    float invDenom = 1.0 / (1.0 + r2);
    float2 xz = 2.0 * p * invDenom;
    float y = (1.0 - r2) * invDenom;
    return float3(xz.x, upper ? y : -y, xz.y);
}

// The dome has no mip chain, while grazing cloud rays cover a very long and anisotropic footprint.
// A single bilinear lookup therefore exposes individual azimuth texels as vertical bars at eye level.
// Apply a small azimuthal footprint only near the horizon; away from it this is exactly one lookup and
// retains the full cloud detail. Rotating the direction also keeps the filter correct around the whole
// circular horizon, unlike applying a fixed offset in atlas UV space.
public float4 sampleCloudDomeFiltered(Sampler2D dome, float3 dir) {
    float4 center = dome.SampleLevel(cloudDomeUv(dir), 0.0);
    float horizonWeight = 1.0 - smoothstep(0.03, 0.12, abs(dir.y));
    if (horizonWeight <= 0.0) {
        return center;
    }

    static const float AZIMUTH_TEXEL = 0.0032;
    float s = sin(AZIMUTH_TEXEL);
    float c = cos(AZIMUTH_TEXEL);
    float s2 = 2.0 * s * c;
    float c2 = c * c - s * s;
    float2 xz = dir.xz;
    float3 leftDir = float3(c * xz.x + s * xz.y, dir.y, -s * xz.x + c * xz.y);
    float3 rightDir = float3(c * xz.x - s * xz.y, dir.y, s * xz.x + c * xz.y);
    float3 farLeftDir = float3(c2 * xz.x + s2 * xz.y, dir.y, -s2 * xz.x + c2 * xz.y);
    float3 farRightDir = float3(c2 * xz.x - s2 * xz.y, dir.y, s2 * xz.x + c2 * xz.y);
    float4 filtered = center * 0.375
            + dome.SampleLevel(cloudDomeUv(leftDir), 0.0) * 0.25
            + dome.SampleLevel(cloudDomeUv(rightDir), 0.0) * 0.25
            + dome.SampleLevel(cloudDomeUv(farLeftDir), 0.0) * 0.0625
            + dome.SampleLevel(cloudDomeUv(farRightDir), 0.0) * 0.0625;
    return lerp(center, filtered, horizonWeight);
}

// Production dual-lobe cloud phase: forward HG lobe, backscatter lobe, and anti-solar silver lining boost.
public float cloudPhase(float cosTheta) {
    float g = 0.85;
    float sqrG = g * g;
    float a = (1.0 - sqrG) / (2.0 + sqrG);
    float b = (1.0 + cosTheta * cosTheta)
            / pow(max(-2.0 * g * cosTheta + 1.0 + sqrG, 1.0e-4), 1.5);
    float forward = max(1.5 * a * b + g * cosTheta, 0.0);
    float gb = -0.3;
    float sqrGb = gb * gb;
    float ab = (1.0 - sqrGb) / (2.0 + sqrGb);
    float bb = (1.0 + cosTheta * cosTheta)
            / pow(max(-2.0 * gb * cosTheta + 1.0 + sqrGb, 1.0e-4), 1.5);
    float back = max(1.5 * ab * bb + gb * cosTheta, 0.0);
    float gz = 0.7;
    float hg = (1.0 - gz * gz)
            / pow(max(1.0 + gz * gz - 2.0 * gz * cosTheta, 1.0e-4), 1.5);
    return lerp(lerp(forward, back * 0.3, 0.25), hg * 1.414, 0.15) * (0.5 / SKY_PI) + 0.014;
}
