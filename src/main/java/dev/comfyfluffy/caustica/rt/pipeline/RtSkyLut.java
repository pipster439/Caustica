package dev.comfyfluffy.caustica.rt.pipeline;

import com.mojang.blaze3d.vulkan.VulkanCommandEncoder;
import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtDebugLabels;
import dev.comfyfluffy.caustica.rt.accel.RtImage;
import dev.comfyfluffy.caustica.rt.gen.PushAddrData;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;
import org.lwjgl.vulkan.VkCommandBuffer;
import org.lwjgl.vulkan.VkComputePipelineCreateInfo;
import org.lwjgl.vulkan.VkDescriptorImageInfo;
import org.lwjgl.vulkan.VkDescriptorPoolCreateInfo;
import org.lwjgl.vulkan.VkDescriptorPoolSize;
import org.lwjgl.vulkan.VkDescriptorSetAllocateInfo;
import org.lwjgl.vulkan.VkDescriptorSetLayoutBinding;
import org.lwjgl.vulkan.VkDescriptorSetLayoutCreateInfo;
import org.lwjgl.vulkan.VkDevice;
import org.lwjgl.vulkan.VkPipelineLayoutCreateInfo;
import org.lwjgl.vulkan.VkPipelineShaderStageCreateInfo;
import org.lwjgl.vulkan.VkPushConstantRange;
import org.lwjgl.vulkan.VkSamplerCreateInfo;
import org.lwjgl.vulkan.VkShaderModuleCreateInfo;
import org.lwjgl.vulkan.VkWriteDescriptorSet;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.LongBuffer;

import static dev.comfyfluffy.caustica.rt.RtContext.check;
import static dev.comfyfluffy.caustica.rt.pipeline.RtBindings.*;

/**
 * The sky's three LUTs (Hillaire 2020) plus the volumetric cloud dome, and the compute passes that bake
 * them. See {@code shaders/pipelines/world/sky.slang} for the atmosphere physics and
 * {@code shaders/pipelines/world/clouds.slang} for the cloud field.
 *
 * <ul>
 *   <li><b>Transmittance</b> 256x64 — point-to-space extinction by (altitude, cos zenith). Static.</li>
 *   <li><b>Multiple scattering</b> 32x32 — the static closed series of second and higher scattering
 *       orders that lights twilight and the night sky.</li>
 *   <li><b>Sky view</b> 192x216 — the dome itself, one 192x108 slice per celestial body, rebuilt every
 *       frame from the sun/moon angles in {@code WorldPush}.</li>
 *   <li><b>Cloud dome</b> 384x216 — volumetric cloud in-scatter (RGB) and transmittance (A) along every
 *       sky direction, rebuilt every frame in the overworld so no radiance ray ever marches clouds.</li>
 * </ul>
 *
 * <p>The two static LUTs are baked on the first frame rather than at construction: they read the ground
 * albedo from the look package through the frame's {@code WorldPush} slot, so they need a frame's push
 * buffer to exist. All passes share one descriptor set and one pipeline layout — every pass
 * declares all six bindings, and each uses the subset it needs.
 *
 * <p>The images are single-buffered. The bake and the trace that reads it run in the same submission with
 * a barrier between, and the composite's end-of-frame barrier orders the next frame's overwrite against
 * this frame's trace — the same argument that lets every other GPU-written per-frame image here be
 * single-buffered.
 */
public final class RtSkyLut {
    private static final String SHADER_DIR = "/caustica/shaders/pipelines/sky_lut/";
    // Keep in lock-step with the same-named constants in shaders/pipelines/world/sky.slang.
    public static final int TRANSMITTANCE_WIDTH = 256;
    public static final int TRANSMITTANCE_HEIGHT = 64;
    public static final int MULTISCATTER_WIDTH = 32;
    public static final int MULTISCATTER_HEIGHT = 32;
    public static final int SKY_VIEW_WIDTH = 192;
    public static final int SKY_VIEW_SLICE_HEIGHT = 108;
    public static final int SKY_VIEW_BODY_COUNT = 2;
    public static final int SKY_VIEW_HEIGHT = SKY_VIEW_SLICE_HEIGHT * SKY_VIEW_BODY_COUNT;
    // Keep in lock-step with shaders/pipelines/sky_lut/clouds.comp.slang.
    public static final int CLOUD_DOME_WIDTH = 1280;
    public static final int CLOUD_DOME_HEIGHT = 640;
    // Keep in lock-step with shaders/pipelines/sky_lut/noise3d.comp.slang.
    public static final int SHAPE_NOISE_SIZE = 128;
    public static final int CURL_NOISE_SIZE = 64;
    private static final int GROUP_SIZE = 8;
    private static final int NOISE_GROUP_SIZE = 4;

    private final RtContext ctx;
    private final RtImage transmittance;
    private final RtImage multiScatter;
    private final RtImage skyView;
    private final RtImage cloudDome;
    private final RtImage cloudShapeNoise;
    private final RtImage cloudCurlNoise;
    private final long sampler;
    private final long cloudDomeSampler;
    private final long noiseSampler;
    private final long descriptorSetLayout;
    private final long descriptorPool;
    private final long descriptorSet;
    private final long pipelineLayout;
    private final long transmittancePipeline;
    private final long multiScatterPipeline;
    private final long skyViewPipeline;
    private final long cloudsPipeline;
    private final long noise3dPipeline;
    private boolean staticLutsBaked;
    private boolean destroyed;

    private RtSkyLut(RtContext ctx, RtImage transmittance, RtImage multiScatter, RtImage skyView,
                     RtImage cloudDome, RtImage cloudShapeNoise, RtImage cloudCurlNoise, long sampler,
                     long cloudDomeSampler, long noiseSampler, long descriptorSetLayout,
                     long descriptorPool, long descriptorSet, long pipelineLayout,
                     long transmittancePipeline, long multiScatterPipeline, long skyViewPipeline,
                     long cloudsPipeline, long noise3dPipeline) {
        this.ctx = ctx;
        this.transmittance = transmittance;
        this.multiScatter = multiScatter;
        this.skyView = skyView;
        this.cloudDome = cloudDome;
        this.cloudShapeNoise = cloudShapeNoise;
        this.cloudCurlNoise = cloudCurlNoise;
        this.sampler = sampler;
        this.cloudDomeSampler = cloudDomeSampler;
        this.noiseSampler = noiseSampler;
        this.descriptorSetLayout = descriptorSetLayout;
        this.descriptorPool = descriptorPool;
        this.descriptorSet = descriptorSet;
        this.pipelineLayout = pipelineLayout;
        this.transmittancePipeline = transmittancePipeline;
        this.multiScatterPipeline = multiScatterPipeline;
        this.skyViewPipeline = skyViewPipeline;
        this.cloudsPipeline = cloudsPipeline;
        this.noise3dPipeline = noise3dPipeline;
    }

    public static RtSkyLut create(RtContext ctx) {
        VkDevice vk = ctx.vk();
        RtImage transmittance = ctx.createStorageImage(TRANSMITTANCE_WIDTH, TRANSMITTANCE_HEIGHT,
                VK10.VK_FORMAT_R16G16B16A16_SFLOAT, "sky transmittance LUT");
        RtImage multiScatter = ctx.createStorageImage(MULTISCATTER_WIDTH, MULTISCATTER_HEIGHT,
                VK10.VK_FORMAT_R16G16B16A16_SFLOAT, "sky multiple-scattering LUT");
        RtImage skyView = ctx.createStorageImage(SKY_VIEW_WIDTH, SKY_VIEW_HEIGHT,
                VK10.VK_FORMAT_R16G16B16A16_SFLOAT, "sky view LUT");
        RtImage cloudDome = ctx.createStorageImage(CLOUD_DOME_WIDTH, CLOUD_DOME_HEIGHT,
                VK10.VK_FORMAT_R16G16B16A16_SFLOAT, "volumetric cloud dome");
        RtImage cloudShapeNoise = ctx.createStorageImage3D(SHAPE_NOISE_SIZE, SHAPE_NOISE_SIZE,
                SHAPE_NOISE_SIZE, VK10.VK_FORMAT_R8G8_UNORM, "cloud shape/erosion noise");
        RtImage cloudCurlNoise = ctx.createStorageImage3D(CURL_NOISE_SIZE, CURL_NOISE_SIZE,
                CURL_NOISE_SIZE, VK10.VK_FORMAT_R8G8B8A8_UNORM, "cloud curl noise");
        try (MemoryStack stack = MemoryStack.stackPush()) {
            // CLAMP on both axes. The sky-view LUT's U axis is angle-from-the-light, which is folded on
            // itself rather than wrapped, and its V axis stacks the two body slices — a REPEAT here would
            // let the sun's rows bleed into the moon's at the seam.
            VkSamplerCreateInfo samplerInfo = VkSamplerCreateInfo.calloc(stack).sType$Default()
                    .magFilter(VK10.VK_FILTER_LINEAR).minFilter(VK10.VK_FILTER_LINEAR)
                    .mipmapMode(VK10.VK_SAMPLER_MIPMAP_MODE_NEAREST)
                    .addressModeU(VK10.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                    .addressModeV(VK10.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                    .addressModeW(VK10.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                    .minLod(0.0f).maxLod(0.0f);
            LongBuffer handle = stack.mallocLong(1);
            check(VK10.vkCreateSampler(vk, samplerInfo, null, handle), "vkCreateSampler(sky LUT)");
            long sampler = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SAMPLER, sampler, "sky LUT sampler");

            // The cloud dome is equirectangular: U wraps around the horizon, V clamps at the poles.
            VkSamplerCreateInfo domeSamplerInfo = VkSamplerCreateInfo.calloc(stack).sType$Default()
                    .magFilter(VK10.VK_FILTER_LINEAR).minFilter(VK10.VK_FILTER_LINEAR)
                    .mipmapMode(VK10.VK_SAMPLER_MIPMAP_MODE_NEAREST)
                    .addressModeU(VK10.VK_SAMPLER_ADDRESS_MODE_REPEAT)
                    .addressModeV(VK10.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                    .addressModeW(VK10.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
                    .minLod(0.0f).maxLod(0.0f);
            check(VK10.vkCreateSampler(vk, domeSamplerInfo, null, handle), "vkCreateSampler(cloud dome)");
            long cloudDomeSampler = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SAMPLER, cloudDomeSampler, "cloud dome sampler");

            // The 3D noise volumes tile on every axis, so the sampler REPEATs all three.
            VkSamplerCreateInfo noiseSamplerInfo = VkSamplerCreateInfo.calloc(stack).sType$Default()
                    .magFilter(VK10.VK_FILTER_LINEAR).minFilter(VK10.VK_FILTER_LINEAR)
                    .mipmapMode(VK10.VK_SAMPLER_MIPMAP_MODE_NEAREST)
                    .addressModeU(VK10.VK_SAMPLER_ADDRESS_MODE_REPEAT)
                    .addressModeV(VK10.VK_SAMPLER_ADDRESS_MODE_REPEAT)
                    .addressModeW(VK10.VK_SAMPLER_ADDRESS_MODE_REPEAT)
                    .minLod(0.0f).maxLod(0.0f);
            check(VK10.vkCreateSampler(vk, noiseSamplerInfo, null, handle), "vkCreateSampler(cloud noise)");
            long noiseSampler = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SAMPLER, noiseSampler, "cloud noise sampler");

            VkDescriptorSetLayoutBinding.Buffer bindings = VkDescriptorSetLayoutBinding.calloc(SKY_LUT_BINDING_COUNT, stack);
            int[] storageBindings = {SKY_LUT_TRANSMITTANCE_IMAGE, SKY_LUT_MULTISCATTER_IMAGE,
                    SKY_LUT_SKY_VIEW_IMAGE, SKY_LUT_CLOUD_DOME_IMAGE,
                    SKY_LUT_CLOUD_SHAPE_IMAGE, SKY_LUT_CLOUD_CURL_IMAGE};
            for (int binding : storageBindings) {
                bindings.get(binding).binding(binding).descriptorType(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
                        .descriptorCount(1).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT);
            }
            int[] sampledBindings = {SKY_LUT_TRANSMITTANCE_SAMPLER, SKY_LUT_MULTISCATTER_SAMPLER,
                    SKY_LUT_CLOUD_SHAPE_SAMPLER, SKY_LUT_CLOUD_CURL_SAMPLER};
            for (int binding : sampledBindings) {
                bindings.get(binding).binding(binding).descriptorType(VK10.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
                        .descriptorCount(1).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT);
            }
            VkDescriptorSetLayoutCreateInfo layoutInfo = VkDescriptorSetLayoutCreateInfo.calloc(stack)
                    .sType$Default().pBindings(bindings);
            check(VK10.vkCreateDescriptorSetLayout(vk, layoutInfo, null, handle),
                    "vkCreateDescriptorSetLayout(sky LUT)");
            long descriptorSetLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET_LAYOUT,
                    descriptorSetLayout, "sky LUT descriptor set layout");

            VkDescriptorPoolSize.Buffer poolSizes = VkDescriptorPoolSize.calloc(2, stack);
            poolSizes.get(0).type(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE).descriptorCount(6);
            poolSizes.get(1).type(VK10.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER).descriptorCount(4);
            VkDescriptorPoolCreateInfo poolInfo = VkDescriptorPoolCreateInfo.calloc(stack)
                    .sType$Default().maxSets(1).pPoolSizes(poolSizes);
            check(VK10.vkCreateDescriptorPool(vk, poolInfo, null, handle),
                    "vkCreateDescriptorPool(sky LUT)");
            long descriptorPool = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_POOL,
                    descriptorPool, "sky LUT descriptor pool");

            VkDescriptorSetAllocateInfo allocateInfo = VkDescriptorSetAllocateInfo.calloc(stack)
                    .sType$Default().descriptorPool(descriptorPool)
                    .pSetLayouts(stack.longs(descriptorSetLayout));
            LongBuffer setHandle = stack.mallocLong(1);
            check(VK10.vkAllocateDescriptorSets(vk, allocateInfo, setHandle),
                    "vkAllocateDescriptorSets(sky LUT)");
            long descriptorSet = setHandle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_DESCRIPTOR_SET,
                    descriptorSet, "sky LUT descriptor set");

            // Same inline address block the trace uses: each pass dereferences the frame's WorldPush
            // through pcAddr.worldPushAddr exactly like the RT stages do.
            VkPushConstantRange.Buffer pushRange = VkPushConstantRange.calloc(1, stack);
            pushRange.get(0).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .offset(0).size(PushAddrData.BYTE_SIZE);
            VkPipelineLayoutCreateInfo pipelineLayoutInfo = VkPipelineLayoutCreateInfo.calloc(stack)
                    .sType$Default().pSetLayouts(stack.longs(descriptorSetLayout))
                    .pPushConstantRanges(pushRange);
            check(VK10.vkCreatePipelineLayout(vk, pipelineLayoutInfo, null, handle),
                    "vkCreatePipelineLayout(sky LUT)");
            long pipelineLayout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE_LAYOUT,
                    pipelineLayout, "sky LUT pipeline layout");

            long transmittancePipeline = createComputePipeline(ctx, stack, pipelineLayout,
                    "transmittance.comp.spv", "sky transmittance pipeline");
            long multiScatterPipeline = createComputePipeline(ctx, stack, pipelineLayout,
                    "multiscatter.comp.spv", "sky multiple-scattering pipeline");
            long skyViewPipeline = createComputePipeline(ctx, stack, pipelineLayout,
                    "view.comp.spv", "sky view pipeline");
            long cloudsPipeline = createComputePipeline(ctx, stack, pipelineLayout,
                    "clouds.comp.spv", "volumetric clouds pipeline");
            long noise3dPipeline = createComputePipeline(ctx, stack, pipelineLayout,
                    "noise3d.comp.spv", "cloud noise bake pipeline");

            VkDescriptorImageInfo.Buffer images = VkDescriptorImageInfo.calloc(SKY_LUT_BINDING_COUNT, stack);
            VkWriteDescriptorSet.Buffer writes = VkWriteDescriptorSet.calloc(SKY_LUT_BINDING_COUNT, stack);
            long[] storageViews = {transmittance.view, multiScatter.view, skyView.view, cloudDome.view,
                    cloudShapeNoise.view, cloudCurlNoise.view};
            for (int i = 0; i < storageViews.length; i++) {
                int binding = storageBindings[i];
                images.get(binding).imageView(storageViews[i]).imageLayout(VK10.VK_IMAGE_LAYOUT_GENERAL);
                writes.get(binding).sType$Default().dstSet(descriptorSet).dstBinding(binding)
                        .descriptorCount(1).descriptorType(VK10.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE)
                        .pImageInfo(VkDescriptorImageInfo.create(images.address(binding), 1));
            }
            long[] sampledViews = {transmittance.view, multiScatter.view,
                    cloudShapeNoise.view, cloudCurlNoise.view};
            long[] sampledSamplers = {sampler, sampler, noiseSampler, noiseSampler};
            for (int i = 0; i < sampledViews.length; i++) {
                int binding = sampledBindings[i];
                images.get(binding).imageView(sampledViews[i]).sampler(sampledSamplers[i])
                        .imageLayout(VK10.VK_IMAGE_LAYOUT_GENERAL);
                writes.get(binding).sType$Default().dstSet(descriptorSet).dstBinding(binding)
                        .descriptorCount(1)
                        .descriptorType(VK10.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
                        .pImageInfo(VkDescriptorImageInfo.create(images.address(binding), 1));
            }
            VK10.vkUpdateDescriptorSets(vk, writes, null);

            return new RtSkyLut(ctx, transmittance, multiScatter, skyView, cloudDome, cloudShapeNoise,
                    cloudCurlNoise, sampler, cloudDomeSampler, noiseSampler, descriptorSetLayout,
                    descriptorPool, descriptorSet, pipelineLayout, transmittancePipeline,
                    multiScatterPipeline, skyViewPipeline, cloudsPipeline, noise3dPipeline);
        }
    }

    public long sampler() {
        return sampler;
    }

    public long transmittanceView() {
        return transmittance.view;
    }

    public long skyViewView() {
        return skyView.view;
    }

    public long cloudDomeView() {
        return cloudDome.view;
    }

    public long cloudDomeSampler() {
        return cloudDomeSampler;
    }

    public long cloudShapeNoiseView() {
        return cloudShapeNoise.view;
    }

    public long cloudCurlNoiseView() {
        return cloudCurlNoise.view;
    }

    public long cloudNoiseSampler() {
        return noiseSampler;
    }

    /**
     * Record this frame's sky LUT work: the two static LUTs on the first frame, then the sky-view LUT,
     * then (in the overworld) the volumetric cloud dome. Must be recorded before the trace, with a
     * barrier after (the caller's) — the miss and raygen stages sample all of these. The cloud dome is
     * skipped outside the overworld because no stage samples it there.
     */
    public void record(VkCommandBuffer cmd, long worldPushAddress, boolean overworld) {
        try (MemoryStack stack = MemoryStack.stackPush();
             RtDebugLabels.Scope ignored = RtDebugLabels.scope(ctx, cmd, "sky LUTs")) {
            VK10.vkCmdBindDescriptorSets(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE,
                    pipelineLayout, 0, stack.longs(descriptorSet), null);
            ByteBuffer push = stack.malloc(PushAddrData.BYTE_SIZE);
            new PushAddrData(worldPushAddress).write(push);
            VK10.vkCmdPushConstants(cmd, pipelineLayout, VK10.VK_SHADER_STAGE_COMPUTE_BIT, 0, push);

            if (!staticLutsBaked) {
                // The cloud noise volumes are static: baked once with the static LUTs, then only sampled.
                dispatch3d(cmd, stack, noise3dPipeline,
                        SHAPE_NOISE_SIZE / NOISE_GROUP_SIZE, SHAPE_NOISE_SIZE / NOISE_GROUP_SIZE,
                        SHAPE_NOISE_SIZE / NOISE_GROUP_SIZE);
                dispatch(cmd, stack, transmittancePipeline, TRANSMITTANCE_WIDTH, TRANSMITTANCE_HEIGHT);
                // The multiple-scattering bake samples the transmittance LUT the previous dispatch just
                // wrote, and the sky-view bake samples both.
                dispatch(cmd, stack, multiScatterPipeline, MULTISCATTER_WIDTH, MULTISCATTER_HEIGHT);
                staticLutsBaked = true;
            }
            dispatch(cmd, stack, skyViewPipeline, SKY_VIEW_WIDTH, SKY_VIEW_HEIGHT);
            if (overworld) {
                dispatch(cmd, stack, cloudsPipeline, CLOUD_DOME_WIDTH, CLOUD_DOME_HEIGHT);
            }
        }
    }

    private void dispatch(VkCommandBuffer cmd, MemoryStack stack, long pipeline, int width, int height) {
        VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        VK10.vkCmdDispatch(cmd, (width + GROUP_SIZE - 1) / GROUP_SIZE,
                (height + GROUP_SIZE - 1) / GROUP_SIZE, 1);
        VulkanCommandEncoder.memoryBarrier(cmd, stack);
    }

    private void dispatch3d(VkCommandBuffer cmd, MemoryStack stack, long pipeline, int gx, int gy, int gz) {
        VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        VK10.vkCmdDispatch(cmd, gx, gy, gz);
        VulkanCommandEncoder.memoryBarrier(cmd, stack);
    }

    public void destroy() {
        if (destroyed) {
            return;
        }
        VkDevice vk = ctx.vk();
        VK10.vkDestroyPipeline(vk, noise3dPipeline, null);
        VK10.vkDestroyPipeline(vk, cloudsPipeline, null);
        VK10.vkDestroyPipeline(vk, skyViewPipeline, null);
        VK10.vkDestroyPipeline(vk, multiScatterPipeline, null);
        VK10.vkDestroyPipeline(vk, transmittancePipeline, null);
        VK10.vkDestroyPipelineLayout(vk, pipelineLayout, null);
        VK10.vkDestroyDescriptorPool(vk, descriptorPool, null);
        VK10.vkDestroyDescriptorSetLayout(vk, descriptorSetLayout, null);
        VK10.vkDestroySampler(vk, noiseSampler, null);
        VK10.vkDestroySampler(vk, cloudDomeSampler, null);
        VK10.vkDestroySampler(vk, sampler, null);
        cloudCurlNoise.destroy();
        cloudShapeNoise.destroy();
        cloudDome.destroy();
        skyView.destroy();
        multiScatter.destroy();
        transmittance.destroy();
        destroyed = true;
    }

    private static long createComputePipeline(RtContext ctx, MemoryStack stack, long layout,
                                              String shader, String label) {
        VkDevice vk = ctx.vk();
        long module = loadModule(vk, stack, SHADER_DIR + shader);
        RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SHADER_MODULE, module, label + " module");
        VkPipelineShaderStageCreateInfo stage = VkPipelineShaderStageCreateInfo.calloc(stack)
                .sType$Default().stage(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                .module(module).pName(stack.UTF8("main"));
        VkComputePipelineCreateInfo.Buffer info = VkComputePipelineCreateInfo.calloc(1, stack);
        info.get(0).sType$Default().stage(stage).layout(layout);
        LongBuffer handle = stack.mallocLong(1);
        check(VK10.vkCreateComputePipelines(vk, VK10.VK_NULL_HANDLE, info, null, handle),
                "vkCreateComputePipelines(" + shader + ")");
        VK10.vkDestroyShaderModule(vk, module, null);
        RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE, handle.get(0), label);
        return handle.get(0);
    }

    private static long loadModule(VkDevice vk, MemoryStack stack, String resource) {
        byte[] bytes;
        try (InputStream input = RtSkyLut.class.getResourceAsStream(resource)) {
            if (input == null) {
                throw new IllegalStateException("missing SPIR-V resource: " + resource);
            }
            bytes = input.readAllBytes();
        } catch (IOException e) {
            throw new IllegalStateException("failed to read SPIR-V resource: " + resource, e);
        }
        ByteBuffer code = MemoryUtil.memAlloc(bytes.length).put(bytes);
        code.flip();
        try {
            VkShaderModuleCreateInfo moduleInfo = VkShaderModuleCreateInfo.calloc(stack)
                    .sType$Default().pCode(code);
            LongBuffer module = stack.mallocLong(1);
            check(VK10.vkCreateShaderModule(vk, moduleInfo, null, module),
                    "vkCreateShaderModule(" + resource + ")");
            return module.get(0);
        } finally {
            MemoryUtil.memFree(code);
        }
    }
}
