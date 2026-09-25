# 影调曲线设计调研

调研对象：Silver 渲染管线中的各条曲线（默认 RAW 曲线、高光过渡、曝光、Highlights / Shadows、Contrast、JPEG 高光过渡），对比 Adobe（DNG SDK 与 Lightroom / Camera Raw）、Apple Core Image、darktable、RawTherapee 的做法。

凡标注“实测”的数据，都是在本机用 Leica M11 样片（`~/Pictures/imports/260527 westcoast` 的 16 张加 `test/L1000914.DNG`）跑出来的。标注“源码”的内容直接摘自公开源码。其余来源见文末参考资料。

---

## 0. 结论摘要

1. **Silver 的默认曲线和 Adobe 的基准曲线本质上是同一条**。Adobe DNG SDK 的 ACR3 默认曲线（`dng_tone_curve_acr3_default`）、Apple `CIRAWFilter` 的默认曲线、Silver 在 0.5 以下使用的曲线，三者输出相差不超过 1 级（8 位 sRGB）。实测，见 §2.2。
2. **最大的差异在“怎么把曲线作用到 RGB 上”**。Adobe 用 `RGBTone`：对最大和最小通道分别套曲线，中间通道按比例插值。它保持色相，但饱和度会像逐通道曲线那样变化。实测 Apple 的默认渲染与这种方式相差 0.71 级。Silver 现在用 max-RGB 等比缩放，相差 3.42 级，并且系统性地偏淡（饱和度偏差 −0.03）。见 §3.3。
3. **白点**：ACR3 曲线在输入 1.0 处精确到达 1.0。Silver 的高光过渡是渐近的，所以曝光 0 时，传感器饱和区域只有 249–253，不是 255。Lightroom PV2012 的曝光用的是“类胶片的柔和高光过渡”，但仍会让真正的白到达白。
4. **Lightroom 的 Highlights / Shadows / Clarity 是局部（边缘感知）算法**，技术来源是 Local Laplacian Filters（Paris 等，2011）。Silver 现在的 Highlights 和 Shadows 都是全局曲线。
5. **实现条件比预想的好**：
   - `CIColorKernel(source:)`（旧的 CIKL 字符串内核，已弃用）在本机仍然可以编译，不装 Metal toolchain 也能写逐像素内核。CLAUDE.md 中“无法写自定义内核”的说法需要修正。
   - Core Image 内置 `CIGuidedFilter`，可以作为局部 Highlights / Shadows 的边缘感知蒙版。

建议的改进顺序见 §6。

---

## 1. Silver 当前的曲线（2026-09-25，commit `7e50bc8`）

| 环节 | 位置 | 当前做法 |
|---|---|---|
| RAW 解码 | `SourceImage` | `CIRAWFilter`，`boostAmount = 0`（关闭 Apple 曲线），`extendedDynamicRangeAmount = 2`（保留大于 1 的高光），白平衡在 RAW 滤镜内完成 |
| 曝光 | `SourceImage.developed` | `CIExposureAdjust` 线性增益，不截断 |
| 默认影调曲线 | `ToneMapping.rawTone` | x ≤ 0.46：实测的 Apple 默认曲线（20 个点，线性插值）。x > 0.46：Reinhard 型渐近尾巴，`y = kv + (1−kv)·t/(1+t)`，斜率连续，永远到不了 1 |
| 曲线作用方式 | `ToneMapping.apply` | 取 max(R,G,B) 查表，RGB 按同一比例缩放（max-RGB ratio）。输出高于 0.772 时，按平方权重混向白色 |
| Highlights（RAW） | `ToneMapping.shiftHighlights` | 在 log 空间，于枢轴 0.3 到“图像最亮值”之间做 `6.75·t²(1−t)` 形状的鼓包重分配。两端固定，枢轴处斜率连续 |
| Highlights（JPEG）、Shadows | `ImagePipeline.applyTone` | `CIHighlightShadowAdjust`，radius 0（全局） |
| Contrast | `ImagePipeline.applyTone` | sRGB gamma 空间的 5 点 `CIToneCurve`（0.25 / 0.75 各 ±0.075），**逐通道**作用 |
| Vibrance / Saturation | `ImagePipeline.applyTone` | `CIVibrance` / `CIColorControls` |
| JPEG 高光过渡 | `ToneMapping.shoulder` | 0.75 以下不变，以上用指数肩部。只在曝光大于 0 时启用 |

---

## 2. Adobe 的做法

### 2.1 DNG SDK 参考渲染管线（源码）

DNG SDK 的 `dng_render` 是 Adobe 公开的 DNG 参考渲染器。它不等于 Lightroom 的完整算法，但定义了 Camera Raw 的基础模型。`dng_render_task::ProcessArea` 对每一行的处理顺序是：

1. 相机原生值 → 线性 ProPhoto RGB（`DoBaselineABCDtoRGB`，包含白平衡和色彩矩阵）
2. `HueSatMap`（profile 的色相 / 饱和度 / 明度表，按白平衡插值）
3. **曝光斜坡** `fExposureRamp`（R、G、B 各自查同一张 1D 表）
4. `LookTable`（profile 的“风格”表）
5. **基准影调曲线** `DoBaselineRGBTone(..., fToneCurve)`
6. 转到输出色彩空间并做 gamma 编码（默认 sRGB）

**曝光斜坡**（`dng_function_exposure_ramp`）：

```cpp
exposure = 用户曝光 + TotalBaselineExposure - log2(Stage3Gain);
white = 1.0 / pow(2.0, Max(0.0, exposure));   // 正曝光 = 线性放大后在 1.0 截断
black = Shadows * ShadowScale * Stage3Gain * 0.001;   // Shadows 默认 5.0
```

`Evaluate` 的结果：
- x ≤ black − r 时为 0；
- 在 black ± r 之间是二次“脚趾”，`fQScale·y²`；
- 之后是 `(x − black)·slope`，并在 1.0 截断。

脚趾半径 `r = min(0.5·black, (1/16)/slope)`。

→ 参考实现里**正曝光是硬截断**：放大后超过 1 的部分直接被切掉。

**负曝光**（`dng_function_exposure_tone`）：不是简单缩小，而是“模拟变暗、同时保持纯白还是纯白”：

```cpp
slope = pow(2, exposure);          // exposure < 0
a = 16/9 * (1 - slope);  b = slope - 0.5*a;  c = 1 - a - b;
y = x <= 0.25 ? x * slope : (a*x + b)*x + c;   // 0.25 以下线性变暗，以上二次过渡，f(1) = 1
```

它和影调曲线串联在一起：`dng_1d_concatenate(exposureTone, ToneCurve)`。

**影调曲线的来源**（`dng_render` 构造函数）：
- 场景参考（scene-referred）数据：默认用 `dng_tone_curve_acr3_default`，这是一张 1025 点的表，输入 0–1 线性，输出 0–1 线性。
- 如果相机 profile 带有 `ProfileToneCurve`，就改用 profile 的曲线。
- 如果 profile 的 `DefaultBlackRender` 为 None，默认的 Shadows 5.0 置 0。
- 非场景参考数据：用恒等曲线，Shadows 也为 0。

### 2.2 ACR3 默认曲线 vs Apple vs Silver（实测）

ACR3 曲线表来自源码。Apple 曲线是在 17 张 M11 上逐通道对比 `boostAmount` 1 和 0 测出来的。Silver 曲线是当前代码。输出都转成 8 位 sRGB：

| 线性输入 | 0.01 | 0.02 | 0.05 | 0.09 | 0.18 | 0.25 | 0.35 | 0.5 | 0.7 | 0.9 | 1.0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ACR3（Adobe） | 23 | 40 | 78 | 114 | 167 | 191 | 212 | 232 | 246 | 253 | **255** |
| Apple 默认 | 23 | 40 | 77 | 115 | 167 | 190 | 211 | 231 | 246 | 253 | 254 |
| Silver 当前 | 23 | 40 | 77 | 115 | 167 | 190 | 211 | 231 | **241** | **245** | **246** |

ACR3 各处的斜率：0.18 处 2.13，0.5 处 0.76，0.9 处 0.22，0.99 处 0.14。18% 灰映射到 0.388（线性），即 sRGB 167。

结论：
- 0.5 以下三者一致。Apple 很可能直接沿用了 Adobe 的基准曲线，或非常接近的一条。
- Silver 为了保留曝光后大于 1 的数据，把 0.46 以上换成了渐近尾巴。代价是 0.7–1.0 这段比 Adobe 暗了 5–9 级，传感器饱和的地方到不了 255。

### 2.3 `RGBTone`：Adobe 如何把曲线作用到 RGB（源码）

`dng_reference.cpp` 中的 `RefBaselineRGBTone`：

```cpp
// 对每个像素，按大小排序为 max ≥ mid ≥ min
rr = table(max);            // 最大通道套曲线
bb = table(min);            // 最小通道套曲线
gg = bb + (rr - bb) * (mid - min) / (max - min);   // 中间通道按原比例插值
// 三通道相等时退化为直接套曲线
```

性质：
- **色相保持**：中间通道在 min–max 之间的相对位置不变，所以在 RGB 六角锥模型里色相不变。逐通道曲线在高光会把橙色推向黄、把天蓝推向青，这里不会。
- **饱和度的行为和逐通道曲线相同**：max 和 min 各走曲线。在曲线陡的中间调，max 与 min 的差被放大，颜色变浓。在曲线趋平的高光，差被压缩，颜色自然淡向白色。所以它不需要额外的“向白混合”。
- **成本很低**：每个像素只查两次表。

RawTherapee 的 “Film-like” 曲线模式（源码 `rtengine/curves.h` 中的 `AdobeToneCurve::RGBTone`，在 `improcfun.cc` 里注释为 “Adobe like”）就是这段代码的移植。

### 2.4 Lightroom / Camera Raw PV2012 及以后（产品行为）

DNG SDK 只是参考渲染。Lightroom 从 PV2012（Lightroom 4，2012）开始的 Basic 面板算法更复杂，而且大部分**没有公开**。可以确认的有：

- **Highlights、Shadows、Clarity 基于 Local Laplacian Filters**。Adobe Lightroom Journal 的文章《Magic or Local Laplacian Filters?》（2012-02）说明，Lightroom 4 的 Highlights / Shadows / Clarity 用的就是 Sylvain Paris（Adobe）等人在 SIGGRAPH 2011 发表的这项技术。多篇二手资料也引用了这一点。
- **Local Laplacian Filters 的原理**（论文原文）：
  - 对输出拉普拉斯金字塔的每个系数，以该处高斯金字塔的值 g₀ 为中心，对原图做逐点重映射，再取重映射后图像在同一位置的拉普拉斯系数。
  - 重映射函数分两段。|i − g₀| ≤ σr 视为细节：`r_d = g₀ + sign·σr·f_d(|i−g₀|/σr)`，其中 `f_d(Δ) = Δ^α`，α < 1 增强细节。更大的差异视为边缘：`r_e = g₀ + sign·(f_e(|i−g₀|−σr) + σr)`，其中 `f_e(a) = β·a`，β < 1 压缩大尺度反差。
  - 做影调映射时，只处理强度通道 `I = (20R + 40G + B)/61` 的对数，颜色比例保持不变。论文默认 σr = log(2.5)。
  - 关键性质：大尺度反差被压缩（高光压下、阴影提亮），细节和边缘保持锐利，不产生光晕。这正是全局曲线做不到的：全局曲线压缩高光时，高光里的局部反差也一起被压扁。
- **曝光是“类胶片”的高光过渡**：二手资料称，Adobe 的 Eric Chan 在论坛中解释过，PV2012 的 Exposure 没有模仿传感器在白点的硬截断，而是借鉴了胶片更柔和的高光过渡。原帖所在的 forums.adobe.com 已经下线，本次无法核实原文。
- **“0 不是中性”**：PV2012 的控件会根据图像内容调整。Adobe 社区里的说法是，各控件在 0 时会被设成“对这张图的范围最有用”的状态，所以没有真正意义上的线性或中性零点（Jeff Schewe 等人的帖子）。
- **高光重建**：Adobe 白皮书《Highlight Recovery in Camera Raw》（Camera Raw 2.x 时期）说明，当一两个通道已经饱和时，Camera Raw 会用未饱和通道的数据，以亮度信息的形式重建高光，通常能多拿回 1–2 档。PV2012 的 Highlights 同样会利用多通道数据重建过曝细节。
- **Whites / Blacks**：分别控制白、黑的裁切点。Highlights / Shadows 作用在曲线两端内侧，Whites / Blacks 作用在两端本身。Adobe 帮助页本次无法访问（403），依据是二手资料和通行描述。
- **Profile**：
  - Adobe Standard / Adobe Color 等 DCP 可以带 `LookTable` 和 `ProfileToneCurve`，Lightroom 默认 profile 的对比度来自这里。用户这张 DNG 里内嵌的 “PROFILE M11” 的 LookTable 是 3×2×1 的恒等表。
  - Lightroom 写进 DNG 的设置里 `ToneCurveName2012="Linear"`：点曲线是线性的，对比度来自 profile 和 Basic 面板，不来自点曲线。

---

## 3. Apple Core Image

### 3.1 `CIRAWFilter` 的影调相关属性（SDK 头文件原文要点）

- `boostAmount`：全局影调曲线的量。0 为线性响应，1 为完整曲线，默认 1。
- `boostShadowAmount`：暗部提升，0–2，默认 1。`boostAmount` 为 0 时无效。
- `baselineExposure`：默认值因图而异。M11 实测为 0.15。
- `shadowBias`：“从阴影中减去的量”。M11 实测默认 5.0，**与 DNG SDK 的 Shadows 默认值 5.0 一致**，说明 Apple 沿用了 DNG 的黑点模型。
- `extendedDynamicRangeAmount`：0–2，允许输出大于 1。
- `highlightRecoveryEnabled`（macOS 26 新增）：高光恢复开关。M11 实测为“支持，默认开启”。
- `localToneMapAmount`：局部影调映射。M11 实测“不支持”。
- `contrastAmount`：作用于边缘的局部对比度。M11 实测支持，默认 0。

### 3.2 默认曲线

见 §2.2：与 ACR3 基本重合。

### 3.3 Apple 如何作用曲线（实测）

做法：用同一条（Apple 实测）曲线，把 `boostAmount = 0` 的线性输出按三种方式映射，与 Apple 自己的 `boostAmount = 1` 输出逐像素比较。样本是 7 张 M11，每张缩到 8%。

| 作用方式 | 与 Apple 的平均误差（8 位） | 饱和度偏差 |
|---|---|---|
| Adobe `RGBTone` | **0.71 级** | −0.003 |
| 逐通道 | 0.75 级 | −0.003 |
| max-RGB 等比缩放（Silver 当前） | 3.42 级 | **−0.030** |

结论：
- Apple 的渲染等价于 `RGBTone` 或逐通道。两者在这批样本上几乎无法区分，因为差别主要出现在高饱和的高光里。
- Silver 的 max-RGB 等比缩放保持了线性空间里的色度比例，但没有得到曲线中段的饱和度增益，所以整体偏淡。这是曝光 0 时 Silver 与原 Apple 渲染差 1–6 级的主因。
- 之前加的“向白混合”只是在补偿等比缩放在高光里不会自然变淡的问题。

### 3.4 可用的积木（实测可用）

| 滤镜 | 用途 |
|---|---|
| `CIColorKernel(source:)`（CIKL，已弃用但可用） | 直接写 `RGBTone` 或任意逐像素曲线，不需要 Metal toolchain |
| `CIGuidedFilter`（inputImage、inputGuideImage、inputRadius、inputEpsilon） | 边缘感知蒙版，可做 tone equalizer 风格的局部 Highlights / Shadows |
| `CIEdgePreserveUpsampleFilter` | 在低分辨率计算蒙版，再边缘感知地放大，省性能 |
| `CIHighlightShadowAdjust` | Apple 自带的高光 / 阴影。radius 0 基本是全局效果（实测与分辨率无关）。radius 大于 0 时是局部效果，但半径以像素计，预览和导出需要按比例换算 |
| `CIColorCubeWithColorSpace` | 3D LUT。可以不用内核，近似实现依赖 (max, min) 的二维映射 |
| `CIToneMapHeadroom` / `CISystemToneMap` | Apple 的 HDR 到 SDR 影调映射，本次未评估 |

---

## 4. 开源方案

### 4.1 darktable（场景参考工作流）

- **filmic rgb**：
  - 以中灰为基准，用“白 / 黑相对曝光”（中灰到白、中灰到黑各有几档）把场景动态范围做对数编码，再套 S 曲线。S 曲线的参数是中段斜率（contrast）、线性区宽度（latitude）和目标中灰。
  - 保色模式对高光的影响：none（逐通道，暗部变浓、高光变淡）、max RGB（天空易偏暗，通道饱和处可能出现边缘伪影）、luminance Y（红色变暗）、power norm（通常是折中）、euclidean norm（高光更淡，最接近胶片）。
- **sigmoid**：
  - 广义 log-logistic 曲线，在无穷远处渐近到目标白，没有硬截断。contrast 调整压缩强度，中灰不动。skew 在暗部和高光之间转移反差。
  - 两种颜色处理模式：“per channel”（逐通道，接近胶片的彩色层，高光自然过渡到白，色相可能偏，可以用 “preserve hue” 滑块控制保留程度）；“rgb ratio”（等比映射，保持光谱色相，但鲜艳的亮部需要沿光谱线去饱和，否则会超出显示色域）。
  - 手册建议用 per channel，再按图调整色相保留程度。例如日落和火焰，用户常常降低色相保留，得到更“热”的效果。
- **tone equalizer**：
  - 用 guided filter（EIGF）生成边缘感知的亮度蒙版，按曝光档位分段调亮或调暗。
  - 蒙版要模糊区域内的细节，这样同一区域的像素被一致处理，保住局部反差；同时保留区域之间的锐利边界，避免光晕。
  - 手册说它可以替代 shadows and highlights、tone curve 等模块。

### 4.2 RawTherapee

- 曲线模式：Standard、Weighted Standard、Film-like、Saturation and Value Blending、Luminance、Perceptual。
- Film-like 就是 Adobe `RGBTone` 的移植（源码，见 §2.3）。

---

## 5. 逐条对比

| 曲线 / 控件 | Adobe | Apple | Silver 当前 | 差距 |
|---|---|---|---|---|
| 基准曲线 0–0.5 | ACR3 表 | ≈ ACR3 | ≈ Apple | 无 |
| 基准曲线 0.5–1 | ACR3，精确到达 1.0 | ≈ ACR3 | 渐近尾巴，1.0 时只有 246 | 高亮暗 5–9 级，白不够白 |
| 大于 1 的数据 | SDK：截断。PV2012：类胶片过渡 + 高光重建 | 靠 EDR 输出保留 | 渐近尾巴，一直延伸到 64 | 方向对，但与“1.0 为白”不一致 |
| 曲线作用方式 | `RGBTone`（保色相，饱和度随曲线变化） | ≈ `RGBTone` / 逐通道 | max-RGB 等比 + 向白混合 | 偏淡 3%，平均差 3.4 级 |
| 正曝光 | SDK：线性 + 截断。PV2012：类胶片过渡 | `exposure` 属性 | 线性增益，交给曲线过渡 | 思路一致 |
| 负曝光 | 0.25 以下线性变暗，以上二次过渡，白保持白 | — | 纯线性增益，白会变灰 | 行为不同，Adobe 保白 |
| Highlights | 局部（Local Laplacian），会重建多通道高光 | `CIHighlightShadowAdjust` | RAW：全局 log 鼓包。JPEG：CI 滤镜 | 缺少局部性，高光里的局部反差会被压扁 |
| Shadows | 局部（Local Laplacian） | 同上 | `CIHighlightShadowAdjust`，radius 0（全局） | 缺少局部性 |
| Whites / Blacks | 调整两端裁切点 | `shadowBias` 近似黑点 | 无 | 缺少功能 |
| Contrast | 属于影调模型的一部分（profile 曲线 + 图像自适应） | — | gamma 空间 5 点曲线，逐通道 | 会造成色相偏移，与主曲线分离 |

---

## 6. 建议（按收益和风险排序）

每一项实施前后都需要做新旧对比基准测试（交替顺序，避免文件冷缓存造成的偏差）。

1. **把曲线作用方式改成 `RGBTone`**（收益最大，风险低）
   - 用一个 CIKL 字符串内核实现：排序 → 最大、最小通道查表 → 中间通道插值。曲线表可以作为 1D 图像传入，或者保留现在的 `CIColorCurves` 分别作用于 `CIMaximumComponent` 和 `CIMinimumComponent`，最后用内核合成。
   - 预期：曝光 0 时与 Apple 原渲染的差距从约 3.4 级降到约 0.7 级，饱和度恢复。高光可以自然淡向白色，“向白混合”蒙版可以删掉。
   - 需要决定：接受已弃用的 CIKL，还是安装 Metal toolchain（`xcodebuild -downloadComponent MetalToolchain`）改写成 Metal CI 内核。无论哪种，都要同步修正 CLAUDE.md 中关于内核的说明。
2. **让白点落在白上**（中等收益，会轻微改变默认效果）
   - 0–1 区间精确采用 ACR3 或 Apple 曲线（1.0 → 1.0）。
   - 大于 1 的部分（只有曝光为正或 EDR 余量时才会出现）压缩到“图像最亮值 → 1.0”。最亮值已经在做 Highlights 时测出来了，可以复用。
   - 这样曝光 0 时，传感器饱和区域就是 255；正曝光时仍然保留类胶片的高光过渡。
3. **负曝光采用 Adobe 的保白方式**（小改动）：0.25 以下线性变暗，以上二次过渡到 1。
4. **Contrast 并入主曲线**：以中灰为枢轴生成 S 形，与基准曲线合成一张表，一起走 `RGBTone`。去掉逐通道的 `CIToneCurve`，避免色相偏移。
5. **局部 Highlights / Shadows**（收益高，成本也高，需要原型验证）：
   - 仿 darktable tone equalizer：在低分辨率计算 log 亮度 → `CIGuidedFilter` 得到边缘感知蒙版 → `CIEdgePreserveUpsampleFilter` 放大 → 按蒙版亮度对 Highlights / Shadows 施加曝光增益。
   - 半径必须按图像尺寸比例设定，保证预览和导出一致。
   - Local Laplacian 效果最好，但即使用 Aubry 等人 2014 年的 Fast LLF，在 Core Image 里实现也不轻，排在后面考虑。
6. **Whites / Blacks 滑块**：在第 2 项之后很自然。直接调整曲线的白点和黑点（黑点可以对应 DNG 的 Shadows / `shadowBias` 模型）。

---

## 7. 局限

- Lightroom PV2012 及以后的具体曲线、局部算法参数、“图像自适应”规则都没有公开。本文关于 Lightroom 产品行为的描述，一部分来自二手资料，已在正文标注。
- Adobe 帮助页（helpx）和旧论坛（forums.adobe.com）本次无法访问。Eric Chan 关于“类胶片曝光”的原话没有找到一手来源。
- Apple 的“曲线作用方式”是用 7 张 M11 实测推断的，不是 Apple 的文档说明。`RGBTone` 和逐通道在这批样本上无法区分。
- darktable 和 RawTherapee 的描述基于官方手册和源码，没有在本机做对比渲染。

---

## 参考资料

- Adobe DNG SDK 源码（GitHub 镜像）：[dng_render.cpp](https://github.com/aizvorski/dng_sdk/blob/master/source/dng_render.cpp)（曝光斜坡、负曝光曲线、ACR3 默认曲线、渲染顺序）、`dng_reference.cpp`（`RefBaselineRGBTone`）；Android 镜像：[dng_render.cpp](https://android.googlesource.com/platform/external/dng_sdk/+/refs/heads/master/source/dng_render.cpp)
- S. Paris, S. W. Hasinoff, J. Kautz, [Local Laplacian Filters: Edge-aware Image Processing with a Laplacian Pyramid](https://people.csail.mit.edu/sparis/publi/2011/siggraph/Paris_11_Local_Laplacian_Filters.pdf)，SIGGRAPH 2011
- M. Aubry 等，[Fast Local Laplacian Filters: Theory and Applications](https://jankautz.com/publications/FastLLF_TOG14.pdf)，ACM TOG 2014
- Adobe Lightroom Journal，[Magic or Local Laplacian Filters?](https://blogs.adobe.com/lightroomjournal/2012/02/magic-or-local-laplacian-filters.html)（2012；本次访问时证书错误，内容据检索摘要）
- Adobe，[Highlight Recovery in Camera Raw（白皮书）](https://www.adobe.com/digitalimag/pdfs/highlight_recovery.pdf)
- Adobe Community，[Why "0" should be Zero](https://community.adobe.com/questions-675/why-0-should-be-zero-991023?postid=3664471)（PV2012 零点不中性的讨论）
- Adobe，[Tone Control Adjustment in Lightroom Classic and Adobe Camera Raw](https://helpx.adobe.com/lightroom-classic/help/tone-control-adjustment.html)（本次 403，未能读取）
- Christine Widdall，[Tone Mapping in Lightroom](https://christinewiddall.co.uk/2012/08/tone-mapping-in-lightroom/)（二手资料）
- darktable 手册：[sigmoid](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/sigmoid/)、[filmic rgb](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/filmic-rgb/)、[tone equalizer](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/tone-equalizer/)
- RawTherapee 源码：[rtengine/curves.h](https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/curves.h)（`AdobeToneCurve`）、[rtengine/improcfun.cc](https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/improcfun.cc)
- Apple，`CIRAWFilter.h`（macOS 27 SDK 头文件注释）、[CIRAWFilter 文档](https://developer.apple.com/documentation/coreimage/cirawfilter)
