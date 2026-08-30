# Caustica 性能深度审查报告

审查范围：Java 渲染热路径、Slang 光追/计算着色器、native NGX shim 与 mixin 边界层（约 3.8 万行）。
关键结论均已人工复核源码确认。本报告为本地审查产物，勿提交 Git。

## 实施状态（2026-08-30）

已实施并验证（详见各条目）：

| 项 | 状态 | 验证 |
|---|------|------|
| H1 执行器 in-flight 化 | ✅ 已实施 | `gradlew compileJava` 通过 |
| H2 云影 LUT 化（新 pass `sky_lut/cloud_shadow.comp`：按帧烘焙世界 XZ 锚定的主导天体云影图，NEE 侧一次双线性采样；原点高于云底回退解析求值） | ✅ 已实施 | 全部 15 个阶段 slangc + spirv-val 通过（含 SER 变体）；compileJava + test 通过；描述符经 slang 反射重新生成并双向校验 |
| H3 重复求值缓存（skyDome/sunExtinction 提为局部变量） | ✅ 已实施 | slangc + spirv-val 通过 |
| H4 影子载荷 rayCone（visibility/shadeReservoir 贯通透光锥） | ✅ 已实施 | 全部阶段 slangc + spirv-val 通过（含 SER 变体） |
| H5 acquire 超时 5s → 50ms | ✅ 已实施 | compileJava 通过；swapchain minImageCount 扩容属 vanilla 交换链创建钩子，列为后续项 |
| M1 TLAS PREFER_FAST_TRACE → PREFER_FAST_BUILD | ✅ 已实施（flag 切换） | compileJava 通过；refit（ALLOW_UPDATE + MODE_UPDATE）列为后续项 |

H2 设计要点（供复核）：云影图以穿越中点世界 XZ 参数化（云底以下的着色点，其中点高度与层内截断长度仅是光方向的函数，与原点高度无关，故二维图精确覆盖；行星曲率在该层厚下偏差约 1e-2 方块，远低于 4 方块/纹素）；烘焙与 NEE 共用 `dominantCelestialLight` 与同一密度场，不引入新的视觉契约偏差；1024²×4 方块/纹素、4096 方块窗口，云特征波长远大于纹素；越界处 clamp-to-edge。H3 的另一半（卷云并入 dome 烘焙）经评估**放弃**：卷云注释明确为 4K 原生分辨率细节设计（`highCloudDensityAt` 精细晶纤），烘入 1280×640 dome 会违反 4K 清晰度约束；其成本已由缓存修复部分缓解。M2-M5 与 L 项的处置见下节。

## 中低项处置结论（2026-08-30 实施轮）

- **L4 已实施**（dispatch 后单次 O(n) 移除替代 per-key indexOf），compileJava + test 通过；其余 L 项逐项核查后裁决不修或转后续（见低严重度表内的逐项理由：多为已缓存、栈分配、不可变 API、字节级垃圾或诊断设施）。
- **M3（水下焦散烘图）暂缓**：`waterCaustic` 的逐样本光源抖动（`sampleSquare`）在 DLSS-RR 累积下产生"随深度物理柔化"是有意设计（water.slang:122-123 注释明示）；烘图会以固定光方向固化图样、改变该行为，属视觉契约变更，需游戏内 A/B 后再定。技术上已验证可分离（det 为 h 的二次式，烘 tr(M)/det(M) 双通道即可精确还原），方案备妥。
- **M4（guide 精简命中记录）暂缓**：需新增 SBT 记录与载荷变体，无运行时验证下回归风险高于收益（仅多层彩色玻璃视角受益）。
- **M5（RIS 预采样候选池）暂缓**：注释自证 5.9ms/18ms 收益，但改动 RIS 采样结构，盲改有引入光照偏差/相关噪声的风险；需要帧时间实测与画面对比设备介入。
- **M2（dome 烘焙降本）暂缓**：直接降低云体光照质量，需视觉验证。
- **TLAS refit / swapchain minImageCount**：与 M1/H5 配套的后续项，均需游戏内验证（VUID 行为与 vanilla 交换链创建钩子）。

## 总体评价

代码性能成熟度显著高于典型 Minecraft mod 水准，接近专业引擎层：GPU 资源全部按时间线信号量环形槽复用、销毁延迟到 graphics 时间线推进后；网格化在 worker 线程用 ThreadLocal 池化；无热路径 waitIdle/fence 阻塞（除下述两处）；native 侧用 FFM 平坦 ABI 从根上回避了 JNI 边界的经典坑。剩余问题集中在三类：**per-ray 解析求值未 LUT 化（着色器侧最大开销）**、**GPU 构建与 CPU 录制串行化（CPU 侧最大开销）**、以及一批每帧小分配。

## 优化约束（运行环境前提）

该 Minecraft 实例在 **4K 分辨率**下渲染运行，且已启用 **DLSS 补帧（Frame Generation）**。对任何优化方案均适用以下硬性约束：

1. **4K 清晰度不可妥协**：最低要求是 4K 分辨率下画面清晰不模糊。任何以牺牲 4K 清晰度为代价的优化方案均不可接受——不得降低渲染分辨率（包括内部渲染倍率、升降采样、降分辨率 dome/输出目标直接用于可见像素），不得降低可见像素路径的纹理 mip 偏置或采样质量。
2. **优化必须与 DLSS 协同**：帧率提升应来自真实的渲染负载削减（per-ray 成本、AS 构建、CPU 侧开销），由 DLSS-RR/FG 在其设计位置兑现为流畅度；不得通过降低渲染分辨率、跳帧或削减采样数来"换取"帧率——那既违反约束 1，也会向 DLSS-RR 的时间累积输入低质量样本，反而劣化最终画面。
3. **本报告各项发现的合规性说明**：
   - H1（执行器 in-flight 化）、H5（acquire 超时）、M1（TLAS refit）、M5（RIS 候选池）及全部 L 项是纯 CPU/同步结构优化，不触碰任何像素路径，天然满足约束。
   - H2/H3/M2（云 dome/LUT 化）与 M3（焦散烘图）只替换**光照项**（影子透过率、NEE 项、逃逸 GI 的天空项）的求值方式，最终 4K 图像仍按原生分辨率逐像素光追合成；dome/LUT 是低频光照数据而非可见像素输出，属于 DLSS 协同的正确方向。落地时需遵守 clouds.slang 顶部"bake 与 shadow 路径共享同一密度场"的既有契约，避免烘焙路径与解析路径不一致造成视觉漂移。
   - H4（any-hit 射线锥 LOD）影响的是**影子与 GI 射线的 alpha 测试精度**（远景 cutout 的遮挡判定），radiance 主命中仍按 chit 的 rayCone LOD 走既有路径，不改变可见像素的清晰度；若实测发现远景树影透光变化，可对 shadow 载荷的 mip 设上限兜底。

## 高严重度

### H1. GPU 执行器：每个 build batch 同步等待完成后才录下一个，录制与 GPU 零重叠，等待传导回渲染线程
- `src/main/java/dev/comfyfluffy/caustica/rt/RtGpuExecutor.java:429`（`execute()` 末尾 `waitTimeline(buildTimeline, signalValue)`，`vkWaitSemaphores` 无限超时）
- `:490-501`（`awaitBuildSubmission` 在 `submissionLock.wait()` 上等待）+ `:117`（render 线程 `beginGraphicsUse` 调用它）
- 后果：worker 线程提交 batch 后卡在等 GPU 完成，下一个 batch（往往是本帧 graphics 依赖的 AS）连提交都没发生，render 线程的 `awaitBuildSubmission` 因此实质退化为等待整个 AS build 的 GPU 完成。帧时间被最慢的 AS 构建直接钳制。
- 修复：提交后不等待，把 `(cmdBuffer, signalValue)` 记入 in-flight 队列，下一轮循环用 `vkGetSemaphoreCounterValue` 轮询回收命令缓冲；`awaitBuildSubmission` 即可微秒级返回。

### H2. 每条 NEE 影子射线解析求值云层透过率（每条最多 4 次 3D 噪声采样），本可 dome/LUT 化
- `shaders/pipelines/world/lighting.slang:335-342`（`celestialCloudShadow` → `clouds.slang:250-263` `cloudTransmittanceToward`，中点单次 `cloudDensityAt`）
- `shaders/pipelines/world/clouds.slang:126-179`（`cloudDensityAt`：cover/curl/shape/erosion 共 4 次 `SampleLevel` 3D 采样 + smoothstep 链）
- 调用点：`indirect.rgen.slang:255`（太阳/月亮 NEE）、`:335`（RIS NEE）、`:380`（SSS 第二条影子射线）；`primary.rgen.slang:127-129` 与 `indirect.rgen.slang:141-143` 每条命中 dielectric 的射线再 2 次 `cloudDensityAt`。
- 频率：每个 ndl>0 着色顶点 1 次，SSS 顶点 2 次，随 SPP×反弹数线性放大。
- 修复：朝光源方向的云透过率按帧烘进 dome LUT（cloudDomeLut 基础设施已存在），per-ray 成本降为 1 次 2D 采样。

### H3. sky.rmiss 每条 miss 射线原生分辨率卷云评估 + 重复求值
- `shaders/pipelines/world/sky.rmiss.slang:166-183`：`highCloudDensityAt`（`clouds.slang` `cirrusFbm` = 4 octave × 4 hash + 1 次 3D 采样）在所有 `dir.y > 0.015` 的天空像素和全部逃逸 GI 射线上执行。
- 同文件重复计算：`skyDome(dir,state)` 在 ：176 与 ：187 各算一遍（各含 2 次 LUT 采样 + 2 次 `skyViewLutUv` 的 acos 对）；`transmittanceToSpace(..., sunDir, ...)` 在 ：174 与 ：210 重复。
- 修复：卷云并入 clouds.comp 的每帧 dome 烘焙；重复项缓存为局部变量。

### H4. any-hit 一律采 mip 0，射线锥 LOD 在影子载荷处断链
- `shaders/pipelines/world/any_hit.rahit.slang:65`（实体）、`:151`（方块图集）均 `SampleLevel(uv, 0.0)`；radiance 载荷携带的 `payload.rayCone`（`world_common.slang:189`）在 chit 用于 LOD（`closest_hit.rchit.slang:62-73`），但 `makeShadowPayload`（`trace.slang:95`）把 rayCone 置 0。
- 后果：远景树叶/草丛的每条影子与 GI 射线都做全分辨率 alpha 测试。
- 修复：影子载荷携带 rayCone，any-hit 复用 chit 的 `rayConeTextureLod` 逻辑取 mip。

### H5. DLSS-FG 启用时渲染线程上做 5 秒超时的 acquire
- `src/main/java/dev/comfyfluffy/caustica/rt/RtFramePresenter.java:54`（`ACQUIRE_TIMEOUT_NS = 5s`）、`:126`（`prepareExtraFrames` 每生成帧在渲染线程调 `vkAcquireNextImageKHR`）
- 后果：FIFO present + 每帧多占 swapchain image，image 耗尽时渲染线程阻塞在驱动调用里直至退役，最坏 5 秒。这是直接发生在 DLSS-FG 协同路径上的问题——FG 的增益被 swapchain 供给不足抵消，且阻塞点在渲染线程上殃及真实帧的录制。
- 修复：超时缩到 ~50ms 并失败即跳过本帧 FG；保证 minImageCount ≥ FG 帧数 + 3；或提前到帧头 acquire。注意修复方向是"供给足够的 swapchain image + 快速失败"，不是减少生成帧数——后者等于放弃 FG 增益，违反优化约束。

## 中严重度

### M1. TLAS 每帧全量重建（PREFER_FAST_TRACE + MODE_BUILD），未复用已有的 refit 机制
- `src/main/java/dev/comfyfluffy/caustica/rt/accel/RtAccel.java:1065-1075`（`tlasBuildInfo`：`MODE_BUILD` + `PREFER_FAST_TRACE`）；同文件 1160/1183 行实体 BLAS 已有 `MODE_UPDATE_KHR` 原位 refit 现成模式。
- 修复：TLAS 加 `ALLOW_UPDATE`，实例集仅小幅变化时走 refit；或对逐帧 TLAS 改用 `PREFER_FAST_BUILD`。

### M2. clouds.comp dome 烘焙极重
- `shaders/pipelines/sky_lut/clouds.comp.slang`：1280×640 texel × 48 步 march，稠密步再跑 `cloudLightOD`(≤4 次 density) + `cloudSkyOD`(3 次)，最坏每 texel 数百次 `cloudDensityAt`。
- 修复：dome 降半分辨率 + 时域重投影；light march 减为 2 步；步数随层厚自适应。

### M3. 水下焦散：每次 NEE 顶点 3 次完整 10 波谱求值
- `shaders/pipelines/world/water.slang:136-153`（`waterCaustic` = 3×`causticLanding` → `waterWaveSpectrum`，WAVE_COUNT=10）+ 表面法线又一遍。
- 修复：按帧烘低分辨率 scrolling caustic map 供 NEE 采样；或有限差分 3 点改 2 点。

### M4. dielectric 引导射线跑完整 closest-hit
- `shaders/pipelines/world/guides.slang:171-232` 循环 `traceGuide`；`trace.slang:72-77` 用 `SBT_RADIANCE` + 无 flag，即每次探针做全套 `evaluateMaterial` 页采样，只为读 albedo/roughness。
- 修复：为 guide 建精简 hit record；或限 2 次穿越后退化。

### M5. RIS 每顶点 M 候选的依赖加载链（代码注释已自证 5.9ms/18ms）
- `shaders/pipelines/world/lighting.slang:226-233`（注释）与 `:237-294`（`risInitial` 每候选 span→alias→Light 三级指针追踪）。
- 修复：presampled 候选池共享 POOL 而非 seed（注释已指明方向）。

## 低严重度（每帧堆分配 / 微观开销）

逐项核查后的裁决（2026-08-30 实施轮）：

| # | 位置 | 问题 | 裁决 |
|---|------|------|------|
| L1 | `RtEntities.java:1270-1272,1421,1576,1653` | 每实体/BE 每帧 `new RtAccel.Instance` + `float[12]` | 不修：每帧百字节级垃圾，相对引擎自身 MB 级 young-gen 流量可忽略；改 scratch 需动 4 处装填点，得不偿失 |
| L2 | `RtEntities.java:836-842` | 每名牌实体每帧 1 次 `level.clip` + 3 次堆分配 | 不修：遮挡结果缓存 2-4 帧会引入可见的穿墙名牌滞后闪变，视觉风险大于收益 |
| L3 | `RtComposite.java:1132-1172,1324` | 每帧 `WorldPushData` 记录树 + `BreakEntry[8]` 数组 | 不修：记录不可变，复用只能省 8 槽数组本身；消费者按数组长度取 breakCount，改动面大于收益 |
| L4 | `RtTerrain.java:1045-1046` | dispatch 循环内 `indexOf` O(n) 扫描 | ✅ 已实施：改为 dispatch 后单次 O(n) 反向移除（利用"幸存者必然仍在 queuedReextract"不变式），compileJava + test 通过 |
| L5 | `RtMaterialRegistry.java:685-694` | block-conditional override 逐 quad 线性扫描 | 不修：无此类规则的资源包时列表为空、成本恒为零；仅在装特定包时才有收益 |
| L6 | `RtEntityCollector.java:776-777` | 每 FRAPI quad 一次 `getAtlasOrThrow` + SpriteFinder | 不修：FRAPI 的 `TextureAtlasMixin` 已按图集缓存 SpriteFinder（volatile 字段 + upload 失效），首次调用后近零成本 |
| L7 | `RtEntities.java:966` | 每帧 `new Frustum` | 不修：平面提取只在构造器，无公开重算 API，复用需 accessor hack；每帧一个小对象不值得 |
| L8 | `VulkanDiagnostics.java:243-276` | 每 batch 字符串拼接/`Instant.now()`/synchronized breadcrumb | 不修：breadcrumb 是崩溃取证设施，采样化恰好在最需要时丢失现场；成本有界（每 batch 约 µs 级） |
| L9 | `RtFrameStats.java:245-258` | 启用时每帧 CSV flush + 64 元素排序 | 不修：默认关闭的 opt-in 诊断，启用即接受开销 |
| L10 | `VulkanGpuSurfaceMixin.java:281-312` | 每 present 栈分配 `VkPresentIdKHR`/marker | 不修：MemoryStack 是凸包分配器，纳秒级且无 GC 压力，报告原评估有误 |
| L11 | `ngx_shim.cpp:257,405,549` | `std::malloc` 未判空；`g_lastResult` 非原子 | 后续项：正确性/健壮性问题而非性能；本机无 MSVC+NGX SDK 编译链，盲改 C++ 无法验证 |
| L12 | `closest_hit.rchit.slang:43-47,360` | 每命中 `GetDimensions` + 3 边 LOD | 后续项：需把图集尺寸编入 MaterialHeader，改动 ABI；收益小 |
| L13 | `sky.rmiss.slang:135-136` | 每 miss 重载整个 WorldPush(~700B) | 后续项：需拆分 push 结构，改动面大 |
| L14 | `exposure_hist/main.comp.slang:29,49` | 每线程 `GetDimensions` | 后续项：微优化，与 L12 同类一并处理 |

## 已核实无问题（避免误修）

- 所有 `waitIdle` 仅在 releaseFeature/resize/init 路径，不在热路径。
- Mixin 无热路径分配、无破坏 vanilla early-out、无禁用优化的 @Redirect。
- config TOML 仅启动时 load 一次；`RtLookPackage` 静态单例；`RtEntityCapture` 用 fastutil 原生数组。
- SER 使用正确（`trace_ser.slang:33-35` Trace 与 Invoke 之间 reorder，双重建 payload 缩小活跃集）；小缺口：hint 未区分 entity/terrain，entity 密集场景可把 ENTITY_BIT 折入 hint 高位。
- 无 fp64、无逐射线矩阵求逆、无巨型宏展开；acquire/present 信号量池轮换语义正确。
- RtDlssFg/RtReflex 的 `vkWaitSemaphores`（≤200ms）是有意的 Reflex pacing 机制，非缺陷。

## 建议的修复优先级

1. **H1**（执行器 in-flight 化）—— 局部改动，直接解除 AS build 对帧率的钳制。
2. **H2+H3+M2**（云：影子射线 dome 化 + 卷云入烘 + bake 降本）—— 拿走着色器侧最大一块帧时间，dome 基础设施已铺好路。
3. **H4**（影子载荷携带 rayCone）—— 小改动，远景 cutout 影子射线成本数量级下降。
4. **H5**（acquire 超时）—— 一行常量 + minImageCount 调整。
5. **M1**（TLAS refit/fast-build）—— 实体 BLAS 已有现成 refit 模式可复用。
6. M3-M5 与 L1-L14 按需清理。

所有修复均在"优化约束（运行环境前提）"下执行：4K 原生分辨率渲染不变、可见像素路径的采样质量不降、与 DLSS-RR/FG 协同兑现帧率——本报告列出的方案无一依赖降分辨率或降采样数，落地时若某项优化出现清晰度退让，视为方案不合规，应回退并改走等价的负载削减路径。
