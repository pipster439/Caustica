// Static 3D cloud noise bake, run once with the other static LUTs. Produces the two tiling volumes the
// cloud density field (world/clouds.slang) is built from, following the noise model of a production
// volumetric-cloud implementation:
//
//   * shape noise (R): 128^3 RG8, billowy low-frequency fbm — the base puffs that get eroded;
//   * erosion noise (G): same image, high-frequency fbm — the wispy edge detail subtracted from puffs;
//   * curl noise: 64^3 RGBA8, the curl of three independent potential fields — a divergence-free warp
//     that gives the puffs their swirl instead of straight fbm lobes.
//
// Both volumes are strictly tiling (the lattice wraps on the image size), so the REPEAT samplers the
// field uses are exact, and the volumes are static: wind advects the SAMPLING domain, never the texture.
import world_common;
import bindings;

// Mirrored in RtSkyLut.java; the two must agree exactly.
public static const int SHAPE_NOISE_SIZE = 128;
public static const int CURL_NOISE_SIZE = 64;

public float hash31(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return frac((p.x + p.y) * p.z);
}

// Tiling 3D value noise: wraps cleanly on integer frequency `freq` across unit [0, 1] domain.
public float valueNoise3D(float3 uv, int freq) {
    float3 p = uv * float(freq);
    int3 i = int3(floor(p));
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    int3 i0 = (i % freq + freq) % freq;
    int3 i1 = (i0 + 1) % freq;
    float c000 = hash31(float3(i0.x, i0.y, i0.z));
    float c100 = hash31(float3(i1.x, i0.y, i0.z));
    float c010 = hash31(float3(i0.x, i1.y, i0.z));
    float c110 = hash31(float3(i1.x, i1.y, i0.z));
    float c001 = hash31(float3(i0.x, i0.y, i1.z));
    float c101 = hash31(float3(i1.x, i0.y, i1.z));
    float c011 = hash31(float3(i0.x, i1.y, i1.z));
    float c111 = hash31(float3(i1.x, i1.y, i1.z));
    return lerp(lerp(lerp(c000, c100, u.x), lerp(c010, c110, u.x), u.y),
            lerp(lerp(c001, c101, u.x), lerp(c011, c111, u.x), u.y), u.z);
}

public float fbm3D(float3 uv, int baseFreq, int octaves, float seedOffset) {
    float3 pos = uv + float3(seedOffset, seedOffset * 1.7, seedOffset * 0.6);
    float f = 0.0;
    float amplitude = 0.5;
    float totalAmp = 0.0;
    int freq = baseFreq;
    for (int i = 0; i < octaves; i++) {
        f += amplitude * valueNoise3D(pos, freq);
        totalAmp += amplitude;
        freq *= 2;
        amplitude *= 0.5;
    }
    return f / max(totalAmp, 1.0e-4);
}

public float potential(float3 uv, int baseFreq, float seedOffset) {
    return fbm3D(uv, baseFreq, 3, seedOffset);
}

// Divergence-free curl of three potential fields, evaluated by central differences. The stored range is
// scaled into [0,1] (the sampler reconstructs [-1,1]), saturating the rare strong lobes.
public float3 curlNoise(float3 uv) {
    float e = 1.0 / float(CURL_NOISE_SIZE);
    float inv = 1.0 / (2.0 * e);
    float3 dx = float3(e, 0.0, 0.0);
    float3 dy = float3(0.0, e, 0.0);
    float3 dz = float3(0.0, 0.0, e);
    float axp = potential(uv + dx, 3, 3.1);
    float axm = potential(uv - dx, 3, 3.1);
    float ayp = potential(uv + dy, 3, 3.1);
    float aym = potential(uv - dy, 3, 3.1);
    float azp = potential(uv + dz, 3, 3.1);
    float azm = potential(uv - dz, 3, 3.1);
    float bxp = potential(uv + dx, 3, 9.7);
    float bxm = potential(uv - dx, 3, 9.7);
    float byp = potential(uv + dy, 3, 9.7);
    float bym = potential(uv - dy, 3, 9.7);
    float bzp = potential(uv + dz, 3, 9.7);
    float bzm = potential(uv - dz, 3, 9.7);
    float cxp = potential(uv + dx, 3, 21.3);
    float cxm = potential(uv - dx, 3, 21.3);
    float cyp = potential(uv + dy, 3, 21.3);
    float cym = potential(uv - dy, 3, 21.3);
    float czp = potential(uv + dz, 3, 21.3);
    float czm = potential(uv - dz, 3, 21.3);
    float3 curl;
    curl.x = (cyp - cym - bzp + bzm) * inv;
    curl.y = (azp - azm - cxp + cxm) * inv;
    curl.z = (bxp - bxm - ayp + aym) * inv;
    return curl;
}

[shader("compute")]
[numthreads(4, 4, 4)]
void main(uint3 tid : SV_DispatchThreadID) {
    if (tid.x >= uint(SHAPE_NOISE_SIZE) || tid.y >= uint(SHAPE_NOISE_SIZE)
            || tid.z >= uint(SHAPE_NOISE_SIZE)) {
        return;
    }
    float3 uv = (float3(tid) + 0.5) / float(SHAPE_NOISE_SIZE);
    float fbmShape = fbm3D(uv, 4, 4, 1.3);
    float billow = 1.0 - abs(fbmShape * 2.0 - 1.0);
    float shape = lerp(fbmShape, billow, 0.75);
    float erosion = fbm3D(uv, 8, 4, 5.7);
    cloudShapeNoiseImage[tid] = float4(shape, erosion, 0.0, 1.0);
    if (tid.x < uint(CURL_NOISE_SIZE) && tid.y < uint(CURL_NOISE_SIZE)
            && tid.z < uint(CURL_NOISE_SIZE)) {
        float3 curlUv = (float3(tid.xyz) + 0.5) / float(CURL_NOISE_SIZE);
        float3 curl = curlNoise(curlUv);
        cloudCurlNoiseImage[tid.xyz] = float4(saturate(curl * 0.5 + 0.5), 1.0);
    }
}
