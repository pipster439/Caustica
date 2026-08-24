# PLAN: Nether/End sky, weather, volumetric fog/clouds (local-only, not in Git)

## Current state (what the code does today)

- Physical atmosphere (Hillaire 2020): 3 LUTs baked by `RtSkyLut` compute passes
  (`sky_lut/transmittance.comp`, `multiscatter.comp`, `view.comp`), shared math in
  `world/sky.slang`. `world/sky.rmiss.slang` answers every miss ray with 2 LUT fetches
  + sun/moon disc sprites + procedural stars; disc drawing is gated by
  `PAYLOAD_SHOW_CELESTIAL` (set on primary + specular bounces only, to avoid
  double-counting vs sun NEE).
- NEE: `indirect.rgen` computes `dominantCelestialLight` (sun or moon by delivered lux)
  and shades it with one shadow ray. RIS block-emitter lights are independent.
- No fog, no clouds, no weather, no dimension awareness. `WorldPush.skyLook3.yzw` is
  reserved. WorldPush Java serializer (`WorldPushData`) is generated from Slang
  reflection of `layout_probe.slang`; `RtBindings` likewise from descriptor reflection.
- Sky state is pushed from `RtComposite.skyPush()` via the camera's
  `EnvironmentAttributeProbe` (already used for the 4 celestial angles, star brightness,
  moon phase). The probe ALSO exposes per-dimension `SKY_COLOR`, `FOG_COLOR`,
  `FOG_START_DISTANCE`, `FOG_END_DISTANCE`, `CLOUD_HEIGHT` etc. — the datapack-correct
  source for Nether/End/custom dimensions.
- `Level.getRainLevel(partial)`, `getThunderLevel(partial)`, `dimension()` exist on
  MC 26.2 `ClientLevel`. `ClientLevel.skyFlashTime` (lightning flash) has a private
  getter → add a tiny `ClientLevelAccessor` mixin (matches existing accessor pattern).
- DLSS-RR guides: sky pixels get `gv_hitCamRel = dir*1e6`, zero object motion
  (`guides.slang`/`primary.rgen`); moving clouds would ghost/smear unless the sky guide
  carries cloud motion.

## Design

### 1. WorldPush additions (world_common.slang → auto-regenerated Java serializer)
- `skyLook3`: x ground albedo, **y rain level 0..1, z thunder level 0..1, w lightning flash 0..1**
- new `skyLook4`: x dimension id (0 overworld, 1 nether, 2 end, 3+ custom),
  y cloud coverage, z cloud layer altitude (blocks), w reserved
- new `skyLook5`: xyz linear sRGB→ACEScg vanilla sky color (normalized), w sky luminance anchor (cd/m²)
- new `skyLook6`: xyz vanilla fog color (normalized ACEScg), w fog start distance (blocks)
- new `skyLook7`: x fog end distance (blocks), y cloud frame dt (s), z previous cloud time, w reserved
- new `skyFlags` uint: bit0 volumetric clouds, bit1 weather effects, bit2 volumetric fog

### 2. Java (RtComposite + look package + config)
- `skyPush()`: read dimension key (`level.dimension()` vs `Level.OVERWORLD/NETHER/END`),
  `getRainLevel/getThunderLevel`, flash (accessor mixin), and the probe's
  SKY_COLOR/FOG_COLOR/FOG_START_DISTANCE/FOG_END_DISTANCE/CLOUD_HEIGHT; decode 0xRRGGBB.
  Weather modulates pushed values: fog end shrinks with rain (rain haze); coverage grows
  with rain. Config toggles set skyFlags bits.
- `RtLookPackage`: schema 4→5, add `netherSkyLuminanceCdM2`, `endSkyLuminanceCdM2`
  (photometric anchors for the dimension sky colors) + `weatherSkyGreyCdM2` (rain
  overcast ambient) to `lighting`; update default look.json + validation.
- `RtSkyLut`: add a per-frame cloud dome image (384×216 RGBA16F: RGB = cloud in-scatter,
  A = transmittance viewer→space) + `clouds.comp` compute pipeline; dispatch gated on
  overworld+clouds; expose view/sampler.
- `RtPipeline`: new world-set binding `WORLD_CLOUDS` (combined image sampler,
  MISS|RAYGEN stages); widen `WORLD_SKY_VIEW`/`WORLD_TRANSMITTANCE` stage flags to
  include RAYGEN (primary pass now samples them for the sky guide).
- `CausticaConfig` + `RtVideoOptions` + `en_us.json`: three toggles
  `volumetricClouds`, `weatherEffects`, `volumetricFog` (default true).

### 3. Shaders — sky / dimension / weather (sky.slang, sky.rmiss.slang, view.comp)
- `skyState()` derives: dimension, rain, thunder, flash, cloud params, fog params.
- Overworld: weather multiplies sun/moon illuminance (rain dims direct light), adds a
  grey overcast ambient term in the miss shader, flash boosts sky + ambient briefly.
  All in shared `sky.slang` so LUT bake, miss shader, and NEE stay in lock-step.
- Nether/End (dimension != 0): no atmospheric scattering. Sky = pushed vanilla sky color
  × luminance anchor; direct celestial illuminance = 0 (gate the NEE shadow ray on
  illuminance > 0 so no wasted rays); end additionally keeps the procedural starfield
  (vanilla end sky shows stars); nether gets no stars.
- Sun/moon discs are not drawn outside the overworld (vanilla parity).

### 4. Volumetric clouds (new `clouds.slang` module + new `sky_lut/clouds.comp`)
- One density field, two consumers (kept in one module so they cannot diverge):
  - **Per-frame bake** (like sky_lut): equirectangular low-res dome. For each texel the
    ray from the viewer through the cloud layer is raymarched (≈16 steps, fbm 4-5
    octaves of procedural hash noise — no texture): RGB in-scatter (sun-lit Beer-Lambert
    single scatter + phase) + A = transmittance through the clouds along that direction.
    No per-miss-ray raymarch — the miss shader does ONE bilinear fetch of this dome.
  - **Analytic flat-layer transmittance** for shadow rays: the sun/moon NEE shadow ray,
    on terrain miss, evaluates the density field at the ray's cloud-layer crossing
    (single fbm eval + Beer-Lambert over the crossing length) → cheap positional cloud
    shadows on terrain that move with the wind; same field as the bake.
- Cloud layer: height/coverage from WorldPush (probe CLOUD_HEIGHT, rain-modulated
  coverage/density); world-stable domain via rebased pos + `waterAnchor.xy` (the same
  rebase-proof trick water waves use); wind = constant in the module × time.
- Sun/moon disc occlusion: `sky.rmiss` samples the baked dome at the sun/moon direction
  (small multi-tap average for the drawn disc's angular size) and multiplies the disc
  radiance by that transmittance. PAYLOAD_SHOW_CELESTIAL logic unchanged — clouds only
  attenuate the disc, they never add light, so no double-counting.
- DLSS temporal stability: `primary.rgen`, at a bounce-0 miss, fetches the dome's alpha
  at the ray direction; when a cloud is present it places the sky guide point ON the
  cloud layer (`gv_hitCamRel = camRel + dir * layerDist`) and writes the cloud's
  per-frame wind displacement into `gv_motionObjDisp` so RR reprojects cloud motion
  instead of treating the sky as static. Clear-sky pixels keep the current far-point
  zero-motion guide.

### 5. Volumetric fog (medium.slang additions + indirect.rgen)
- Pushed per-frame `airFog` extinction+color: overworld gets rain haze (extinction
  scaled by rain level, fog end shrinks toward vanilla's rain fog ~32 blocks); nether
  and end use vanilla FOG_START/FOG_END distances and fog color (nether ≈ 33-block red
  fog, end's dark purple) so distant terrain melts into the sky exactly like vanilla.
- Applied in `indirect.rgen` per air segment: `throughput *= exp(-ext*t)` plus airlight
  `L += throughput * fogColorInscatter * (1-exp(-ext*t))`; gated on the segment being in
  air (water/glass media untouched). Miss rays blend the sky toward the fog color by a
  fixed haze factor, so surface-at-infinity == sky color (no seam at the horizon).

## Files touched

Java:
- `RtComposite.java` (skyPush + push fields + bake dispatch gating + dome binding)
- `RtSkyLut.java` (cloud dome image + clouds compute pipeline)
- `RtPipeline.java` (WORLD_CLOUDS binding + stage flags)
- `RtLookPackage.java` + `look.json` (schema 5: nether/end/weather anchors)
- `CausticaConfig.java`, `RtVideoOptions.java`, `en_us.json` (3 toggles)
- new `mixin/ClientLevelAccessor.java` + `caustica.mixins.json` (flash getter)

Shaders:
- `world_common.slang` (WorldPush fields), `bindings.slang` (cloud dome binding)
- `sky.slang` (SkyState: dimension/weather/cloud/fog derivation, illuminance gating)
- `sky.rmiss.slang` (dimension sky, weather grey, flash, disc occlusion)
- new `world/clouds.slang` (shared density field + analytic layer transmittance)
- new `sky_lut/clouds.comp.slang` (dome bake), `sky_lut/bindings.slang` (storage image)
- `indirect.rgen.slang` (fog, cloud-shadowed NEE, illuminance gate)
- `primary.rgen.slang` (sky-pixel cloud motion guide)

## Performance / correctness impact
- GPU: +1 low-res compute pass (~0.2–0.4 ms) per frame in overworld with clouds on;
  +1 texture fetch per miss; +few ALU per NEE shadow-ray miss; fog is a few ALU per
  path vertex. No extra rays, no per-miss raymarch. Expected frame-time delta < 5%.
- Nether/End: sky LUT + cloud bakes skipped; NEE shadow rays gated off → slightly cheaper.
- Correctness invariants: LUT, miss, and NEE all derive from the same `skyState()` and
  the same cloud field; the disc/NEE cloud attenuation share one field so no energy is
  created; PAYLOAD_SHOW_CELESTIAL semantics untouched.

## Risks
1. **Rebase**: cloud domain must survive terrain rebases — solved by the waterAnchor.xy
   trick; a mistake shows as cloud pattern jumping when the player crosses 128-block
   boundaries. Test by walking while watching the sky.
2. **DLSS-RR ghosting on clouds**: motion guide on the cloud layer; cloud speed kept
   slow; verify by strafing/looking around under clouds.
3. **Nether/End exposure**: auto-exposure adapts to the dim ambient; tune the luminance
   anchors in look.json so nether reads like vanilla (lava-lit dark red) and the end is
   dark but not black.
4. **Water/glass regression**: fog gated to air segments; medium extinction untouched.
   Clouds appear in reflections via the same miss path — verify water/glass still fine.
5. **Disc occlusion consistency**: marched dome alpha vs analytic shadow-path
   transmittance are different estimators of the same field; both track density so the
   disc and terrain lighting darken together; worst case is a thin-cloud edge mismatch.
6. **Emissive/RIS unaffected**: fog only attenuates travelled radiance in air — RIS
   shadow rays unchanged (clouds don't shadow block lights; they're below the layer
   or negligible at that scale).

## Verification plan
- Build: cmake shim + `./gradlew runClient --args="--renderDebugLabels --graphicsBackend VULKAN"`.
- Overworld: day → night → day (`/time set`), clear vs `/weather rain` vs
  `/weather thunder`; watch sky, terrain lighting, clouds occluding sun/moon, fog haze.
- `/execute in minecraft:the_nether run tp @s ~ 80 ~` and the_end equivalent; check
  sky color, lava/glowstone lighting, no sun disc, fog falloff.
- Water/glass/entities still render; frame times via debug overlay/F3 unchanged ±5%.
- Toggle each of the three new options in Video Settings and confirm A/B effect.
