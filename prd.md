# Mac 原生照片处理应用 Silver 需求文档

## 1. 产品目标

开发一款极简 Mac 原生照片处理应用，用于替代 Lightroom 中的轻量 RAW 处理流程。

应用只负责：

```
本地 DNG 文件夹
→ 浏览 / 选择照片
→ 基础 light / color 调整
→ 裁切
→ 批量导出 JPG
→ 导入 Apple Photos / iCloud
```


## 2. 目标用户

主要用户为自己，使用 Leica M11 / Q2 拍摄 DNG，并希望保留本地 RAW 文件，只将处理后的 JPG 导入 Apple Photos / iCloud。


## 3. 核心功能

### 3.1 打开文件夹

用户可以选择一个本地文件夹。应用扫描其中的照片文件，优先支持：

```
.dng
.jpg
.jpeg
```

### 3.2 照片浏览

应用显示文件夹中的照片缩略图。用户可以逐张查看、选择、多选照片。

需要支持：

- 缩略图网格；
- 单张大图预览；
- 上一张 / 下一张切换；
- 多选照片。
    

### 3.3 基础编辑

每张照片支持以下调整：

- Exposure
- Contrast
- Highlights
- Shadows
- White Balance / Temperature
- Tint
- Saturation
- Vibrance
- Crop
- Straighten

### 3.4 非破坏性编辑

应用不修改原始 DNG。  
每张照片的编辑参数保存为 sidecar 文件，例如：

```
L1001234.DNG
L1001234.edit.json
```

### 3.5 复制 / 粘贴调整

用户可以将一张照片的编辑参数复制到其他照片。

需要支持：

- Copy Adjustments
- Paste Adjustments
- Paste to Selected
    

### 3.6 批量导出 JPG

用户可以选择一张或多张照片，批量导出 JPG。

导出设置第一版包括：

- JPEG quality；
- 输出文件夹；
- 是否保留 EXIF；
- 色彩空间默认 sRGB；
- 文件名默认沿用原文件名。

### 3.7 导入 Photos

第一版可以只导出到本地文件夹，由用户手动导入 Apple Photos。

后续版本再考虑：

```
Export and Import to Photos
```


## 4. MVP 验收标准

第一版成功标准：

1. 可以打开一个包含 Leica DNG 的文件夹；
2. 可以显示缩略图和大图预览；
3. 可以对单张照片进行基础 light / color 调整；
4. 可以裁切照片；
5. 可以保存编辑参数；
6. 可以复制调整到多张照片；
7. 可以批量导出 JPG；
8. 导出的 JPG 可以正常导入 Apple Photos；

## 5. 产品定位

这不是 Lightroom 替代品。  
它是一个个人化的本地 RAW-to-JPG 工作流工具。

核心价值是：

```
Open Folder
Edit
Apply to Selected
Export JPG
```