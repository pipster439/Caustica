// Complete descriptor and push-constant interface for the world ray-tracing pipeline.
// Every world stage imports this module instead of redeclaring its own subset.

import world_common;

[[vk::push_constant]] public WorldPushConstants pc;

[[vk::binding(0, 0)]] public RaytracingAccelerationStructure topLevelAS;
[[vk::binding(1, 0)]] [format("rgba16f")] public RWTexture2D<float4> outImage;

[[vk::binding(3, 0)]] [format("rgba16f")] public RWTexture2D<float4> gNormal;
[[vk::binding(4, 0)]] [format("rgba16f")] public RWTexture2D<float4> gAlbedo;
[[vk::binding(5, 0)]] [format("r32f")] public RWTexture2D<float> gDepth;
[[vk::binding(6, 0)]] [format("rg16f")] public RWTexture2D<float2> gMotion;
[[vk::binding(7, 0)]] [format("rgba16f")] public RWTexture2D<float4> gSpecAlbedo;
[[vk::binding(8, 0)]] [format("rg16f")] public RWTexture2D<float2> gSpecMotion;

[[vk::binding(2, 0)]] public Sampler2D blockAlbedoAtlas;
[[vk::binding(9, 0)]] public Sampler2D celestialsAtlas;
[[vk::binding(10, 0)]] public Sampler2D skyViewLut;
[[vk::binding(11, 0)]] public Sampler2D transmittanceLut;
// Per-frame volumetric cloud dome (sky_lut/clouds.comp): RGB in-scatter, A transmittance. Sampled by
// world.rmiss (dome + disc occlusion) and primary.rgen (sky-guide cloud motion); celestial shadow rays
// read the cloudShadowLut bake below instead of the dome.
[[vk::binding(12, 0)]] public Sampler2D cloudDomeLut;
// Static tiling 3D cloud noise volumes (sky_lut/noise3d.comp), sampled by the density field in
// clouds.slang from the miss shader (edge recontour) and raygen (shadow-path transmittance).
[[vk::binding(13, 0)]] public Sampler3D cloudShapeNoise;
[[vk::binding(14, 0)]] public Sampler3D cloudCurlNoise;
// Per-frame celestial cloud shadow map (sky_lut/cloud_shadow.comp): R = the dominant light's
// transmittance through the cumulus layer by crossing-midpoint world XZ. Sampled by lighting.slang's
// celestialCloudShadow for every celestial shadow ray below the layer base; points inside or above the
// layer fall back to the analytic field via the noise volumes above.
[[vk::binding(15, 0)]] public Sampler2D cloudShadowLut;

[[vk::binding(0, 1)]] public Sampler2D entityAlbedoTex[];
[[vk::binding(1, 1)]] public Sampler2D materialSurface0Tex[];
[[vk::binding(2, 1)]] public Sampler2D materialNormalAoTex[];
[[vk::binding(3, 1)]] public Sampler2D materialSurface1Tex[];
