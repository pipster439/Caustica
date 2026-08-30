[[vk::binding(0, 0)]] [format("rgba16f")] public RWTexture2D<float4> transmittanceImage;
[[vk::binding(1, 0)]] [format("rgba16f")] public RWTexture2D<float4> multiScatterImage;
[[vk::binding(2, 0)]] [format("rgba16f")] public RWTexture2D<float4> skyViewImage;
[[vk::binding(3, 0)]] public Sampler2D transmittanceLut;
[[vk::binding(4, 0)]] public Sampler2D multiScatterLut;
[[vk::binding(5, 0)]] [format("rgba16f")] public RWTexture2D<float4> cloudDomeImage;
// Static tiling 3D cloud noise volumes (noise3d.comp): shape (R) + erosion (G) in one RG8 volume, the
// curl warp in a separate RGBA8 volume. Each is bound twice — as the bake's write target and as the
// sampler the density field reads — the same pattern the transmittance LUT uses.
[[vk::binding(6, 0)]] [format("rg8")] public RWTexture3D<float4> cloudShapeNoiseImage;
[[vk::binding(7, 0)]] [format("rgba8")] public RWTexture3D<float4> cloudCurlNoiseImage;
[[vk::binding(8, 0)]] public Sampler3D cloudShapeNoise;
[[vk::binding(9, 0)]] public Sampler3D cloudCurlNoise;
// Per-frame celestial cloud shadow map (cloud_shadow.comp): R = the dominant light's Beer-Lambert
// transmittance through the cumulus layer, indexed by the crossing midpoint's world XZ. The world
// pipeline's lighting.slang samples the same image through the Sampler2D view below.
[[vk::binding(10, 0)]] [format("r16f")] public RWTexture2D<float4> cloudShadowImage;
[[vk::binding(11, 0)]] public Sampler2D cloudShadowLut;
