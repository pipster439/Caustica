// Volumetric cloud dome bake, once per frame in the overworld. Marches the shared cloud density field
// (world/clouds.slang) into a low-resolution equirectangular dome: RGB holds the in-scattered cloud
// light, A holds the Beer-Lambert transmittance from the viewer through the layer along that direction.
//
// world.rmiss then answers every sky pixel with one bilinear fetch of this dome instead of a march, and
// sky_lut/cloud_shadow.comp bakes the same field once per world-XZ texel so celestial shadow rays read
// the cloud term from a map instead of re-evaluating the 3D field per ray.
//
// Reads the same WorldPush BDA slot the trace and the sky LUTs do, so the clouds a ray sees and the
// clouds the light samples can never disagree about coverage, altitude, wind time, or the sun.
import world_common;
import sky;
import clouds;
import bindings;

[[vk::push_constant]] PushAddr pcAddr;

// Mirrored in RtSkyLut.java; the two must agree exactly.
public static const int CLOUD_DOME_W = 1280;
public static const int CLOUD_DOME_H = 640;
public static const int CLOUD_MARCH_STEPS = 48;

float cloudLightOD(float3 pos, float3 lightDir, float2 anchor, float cloudAlt, float coverage, float time,
                   Sampler3D shapeNoise, Sampler3D curlNoise) {
    float stepsize = 25.0;
    float od = 0.0;
    float3 p = pos;
    for (int i = 0; i < 4; i++) {
        p += lightDir * stepsize;
        if (p.y > cloudAlt + CLOUD_THICKNESS_BLOCKS || p.y < cloudAlt) {
            break;
        }
        float d = cloudDensityAt(p, anchor, cloudAlt, coverage, time, shapeNoise, curlNoise);
        od += d * stepsize;
        stepsize *= 2.0;
    }
    return od;
}

float cloudSkyOD(float3 pos, float2 anchor, float cloudAlt, float coverage, float time,
                 Sampler3D shapeNoise, Sampler3D curlNoise) {
    float stepsize = 35.0;
    float od = 0.0;
    float3 p = pos;
    for (int i = 0; i < 3; i++) {
        p += float3(0.0, 1.0, 0.0) * stepsize;
        if (p.y > cloudAlt + CLOUD_THICKNESS_BLOCKS) {
            break;
        }
        float d = cloudDensityAt(p, anchor, cloudAlt, coverage, time, shapeNoise, curlNoise);
        od += d * stepsize;
        stepsize *= 1.8;
    }
    return od;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= uint(CLOUD_DOME_W) || tid.y >= uint(CLOUD_DOME_H)) {
        return;
    }
    WorldPush push = ConstPtr<WorldPush>(pcAddr.worldPushAddr)[0];
    SkyState sky = skyState(push);
    float coverage = sky.dimension == DIMENSION_OVERWORLD ? sky.cloudCoverage : 0.0;
    if (coverage <= 0.0) {
        cloudDomeImage[tid.xy] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    float2 uv = (float2(float(tid.x), float(tid.y)) + 0.5)
              / float2(float(CLOUD_DOME_W), float(CLOUD_DOME_H));
    float3 dir = cloudDomeDir(uv);
    float3 origin = push.camOffset.xyz;
    float2 anchor = push.waterAnchor.xy;
    float alt = sky.cloudAltRebased;

    // Atmospheric tint of the celestial bodies at the viewer.
    float3 sunTint = transmittanceToSpace(transmittanceLut, sky.viewerRadiusKm, sky.sunDir,
            sky.sunAngularRadius);
    float3 moonTint = transmittanceToSpace(transmittanceLut, sky.viewerRadiusKm, sky.moonDir,
            sky.moonAngularRadius);
    float sunLux = sky.sunIlluminance * dot(sunTint, float3(0.2126, 0.7152, 0.0722));
    float moonLux = sky.moonIlluminance * dot(moonTint, float3(0.2126, 0.7152, 0.0722));

    float3 lightDir;
    float3 lightColor;
    if (sunLux >= moonLux) {
        lightDir = sky.sunDir;
        lightColor = float3(sky.sunIlluminance) * sunTint;
    } else {
        lightDir = sky.moonDir;
        lightColor = float3(sky.moonIlluminance) * moonTint;
    }

    // Sky-blue ambient skylight for clean, non-muddy pastel shadow crevice illumination
    float3 ambientSky = sampleMultiScatter(multiScatterLut, sky.viewerRadiusKm, lightDir.y) * lightColor;
    ambientSky += float3(0.015, 0.045, 0.11) * sky.sunIlluminance + float3(sky.airglowLuminance);

    float3 transmittance = float3(1.0);
    float3 inscatter = float3(0.0);
    float phaseDirect = cloudPhase(dot(dir, lightDir));

    // ---- March Layer 0: 3D Cumulus Clouds
    float tEnter0, tExit0;
    if (intersectCloudLayer(origin, dir, alt, alt + CLOUD_THICKNESS_BLOCKS, tEnter0, tExit0)) {
        float dt = (tExit0 - tEnter0) / float(CLOUD_MARCH_STEPS);
        // Stratified jitter to break discrete concentric spherical slicing bands
        float jitter = frac(sin(dot(float2(tid.xy), float2(12.9898, 78.233))) * 43758.5453);
        for (int i = 0; i < CLOUD_MARCH_STEPS; i++) {
            if (max(transmittance.r, max(transmittance.g, transmittance.b)) < 0.01) {
                break;
            }
            float t = tEnter0 + (float(i) + jitter) * dt;
            float3 p = origin + dir * t;
            float density = cloudDensityAt(p, anchor, alt, coverage, sky.cloudTime,
                    cloudShapeNoise, cloudCurlNoise);
            if (density <= 0.0) {
                continue;
            }

            float sigma = density * CLOUD_DENSITY;
            float3 stepT = exp(-float3(sigma * dt));

            // 4-step light march and 3-step sky AO for 3D self-shadowing and depth
            float lightOD = cloudLightOD(p, lightDir, anchor, alt, coverage, sky.cloudTime,
                    cloudShapeNoise, cloudCurlNoise);
            float skyOD = cloudSkyOD(p, anchor, alt, coverage, sky.cloudTime,
                    cloudShapeNoise, cloudCurlNoise);

            float lightShadow = exp(-lightOD * CLOUD_DENSITY * 1.5);
            float skyAo = exp(-skyOD * CLOUD_DENSITY * 1.0);
            float powder = 1.0 - exp(-density * CLOUD_DENSITY * 30.0);

            // Multiple forward scattering approximation for sunlit silver linings & billow highlights
            float multiScatterDirect = 0.22 * exp(-lightOD * CLOUD_DENSITY * 0.25) * max(phaseDirect, 0.1);
            float3 directLit = lightColor * (lightShadow * phaseDirect * powder + multiScatterDirect);

            // Ambient skylight with sky AO and ground bounce
            float ambientPhase = 0.5 * (dir.y * 0.5 + 0.5) + 0.5;
            float3 ambientLit = ambientSky * (ambientPhase * (skyAo * 0.75 + 0.25 * lightShadow));
            float3 bounceLit = lightColor * max(lightDir.y, 0.0) * (sky.groundAlbedo * 0.35) * max(-dir.y * 0.5 + 0.5, 0.0);

            float3 lit = directLit + ambientLit + bounceLit;
            float3 stepScatter = lit * (float3(1.0) - stepT);
            inscatter += transmittance * stepScatter;
            transmittance *= stepT;
        }

        float distFade = smoothstep(7000.0, 2500.0, tEnter0);
        transmittance = lerp(float3(1.0), transmittance, distFade);
        inscatter *= distFade;
    }

    cloudDomeImage[tid.xy] = float4(max(inscatter, float3(0.0)), max(transmittance.x, 0.0));
}
