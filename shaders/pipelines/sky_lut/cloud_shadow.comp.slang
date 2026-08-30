// Celestial cloud shadow map bake, once per frame in the overworld, right after the cloud dome.
// Evaluates the shared density field (world/clouds.slang) once per world-XZ texel at the dominant
// light's layer-crossing midpoint and stores the Beer-Lambert transmittance of the full clamped layer
// crossing. lighting.slang then answers every celestial shadow ray's cloud term with one bilinear
// fetch of this map instead of re-evaluating the 3D noise field per ray.
//
// For a shading point strictly below the layer base, the crossing's midpoint altitude and clamped
// in-layer span are constants of the light direction (the flat-slab twin of intersectCloudLayer;
// planetary curvature moves the midpoint by ~1e-2 blocks at this layer thickness, far below a texel),
// so a single world-XZ map covers all of them. Points inside or above the layer keep the analytic
// midpoint evaluation on the NEE side.
//
// Reads the same WorldPush BDA slot the trace and the other sky LUTs do, and derives the dominant
// light with the same dominantCelestialLight() the raygen uses — the map and the NEE it feeds can
// never disagree about coverage, altitude, wind time, or which body is being shadowed.
import world_common;
import sky;
import clouds;
import bindings;

[[vk::push_constant]] PushAddr pcAddr;

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= uint(CLOUD_SHADOW_RES) || tid.y >= uint(CLOUD_SHADOW_RES)) {
        return;
    }
    WorldPush push = ConstPtr<WorldPush>(pcAddr.worldPushAddr)[0];
    SkyState sky = skyState(push);
    float coverage = sky.dimension == DIMENSION_OVERWORLD ? sky.cloudCoverage : 0.0;
    if (coverage <= 0.0) {
        cloudShadowImage[tid.xy] = float4(1.0, 1.0, 1.0, 1.0);
        return;
    }
    float3 lightDir = dominantCelestialLight(sky, transmittanceLut).dir;
    if (lightDir.y <= 0.002) {
        // Body at/below the horizon: cloudTransmittanceToward's dir.y guard also returns full
        // transmittance here, so the map agrees with the analytic path for any NEE that fires anyway.
        cloudShadowImage[tid.xy] = float4(1.0, 1.0, 1.0, 1.0);
        return;
    }
    // Clamped in-layer span for an origin below the base: min(unclamped crossing, MAX_RAY_DIST), exactly
    // the analytic clamp — and independent of the origin's altitude either way.
    float span = min(CLOUD_THICKNESS_BLOCKS, CLOUD_MAX_RAY_DIST * lightDir.y);
    float midAlt = sky.cloudAltRebased + span * 0.5;
    float2 texXz = push.camOffset.xz
            + ((float2(float(tid.x), float(tid.y)) + 0.5) / float(CLOUD_SHADOW_RES) - 0.5)
            * CLOUD_SHADOW_EXTENT_BLOCKS;
    float density = cloudDensityAt(float3(texXz.x, midAlt, texXz.y), push.waterAnchor.xy,
            sky.cloudAltRebased, coverage, sky.cloudTime, cloudShapeNoise, cloudCurlNoise);
    float t = exp(-density * CLOUD_DENSITY * (span / lightDir.y));
    cloudShadowImage[tid.xy] = float4(t, t, t, 1.0);
}
