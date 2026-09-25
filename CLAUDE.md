# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Silver is a minimal native macOS app (SwiftUI, Core Image) for a personal RAW-to-JPEG workflow: browse folders of Leica M11/Q2 DNGs, make basic light/color/crop edits stored in sidecar files, and batch export sRGB JPEGs for Apple Photos. `prd.md` (Chinese) is the product spec. UI text is English.

## Build and run

```sh
# Keep build output out of the repo
xcodebuild -project Silver.xcodeproj -scheme Silver -configuration Debug \
  -derivedDataPath /tmp/SilverDerivedData build
open /tmp/SilverDerivedData/Build/Products/Debug/Silver.app
```

There is no test target and no linter. The imaging and model code is `nonisolated` and has no UI dependencies, so it is tested with throwaway `swiftc` harnesses against real DNGs (test photos are not in the repo):

```sh
cd Silver
swiftc -O -o /tmp/harness \
  Model/EditSettings.swift Imaging/CropGeometry.swift Imaging/ImagePipeline.swift Imaging/ToneMapping.swift \
  Imaging/Thumbnails.swift Model/Exporter.swift Model/Sidecar.swift \
  /path/to/main.swift            # add Model/Bookmarks.swift Model/SourceFolders.swift for sidebar logic
```

The harness file must be named `main.swift` for top-level code (don't pass `-parse-as-library`). When comparing renders, compare 8-bit rendered pixels: `CIAreaAverage` over large cropped extents gives misleading results.

## Project setup gotchas

- The target uses file-system-synchronized groups: any file under `Silver/` is compiled automatically, with no `project.pbxproj` edit needed.
- Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Everything is main-actor unless marked `nonisolated`, and `nonisolated async` functions run on the caller's actor. Heavy work therefore goes through `Task.detached` or the `PreviewRenderer` actor, and value types used off the main actor are declared `nonisolated`.
- App Sandbox: user-selected files are read-write (needed for sidecars and export). `Silver.entitlements` adds app-scoped security bookmarks and is merged with the build-setting entitlements.
- The Metal toolchain is not installed, so custom Core Image kernels are unavailable. Tone mapping is composed from stock filters (`CIMaximumComponent`, `CIColorCurves`, `CIBlendWithMask`, …).

## Architecture

**State.** `LibraryModel` (`@Observable`, owned by `AppDelegate`, injected via `.environment`) is the single source of app state:
- the open folder, selection and active photo
- view mode and the crop session
- an app-level undo/redo stack (not `UndoManager`)
- the coalescing preview render loop and the thumbnail queue
- debounced sidecar saves, via `flushSaves()` on folder change and app termination

`SourceFolders` manages the sidebar. Root folders are persisted as security-scoped bookmarks. Subfolders are listed lazily on expand. Roots on disconnected volumes are kept as unavailable and re-checked on mount, unmount and app activation. Folder URLs are compared after `SourceFolders.normalized(_:)`, because `URL` equality treats trailing-slash differences as unequal.

**Edits.** `EditSettings` is the whole per-photo edit. It is written by `Sidecar` to `<base>.edit.json` next to the original. The sidecar is deleted when settings return to default. When a DNG and a JPG share a base name, the JPG uses `<name>.JPG.edit.json`. Decoding clamps every value to its slider range. Crop rects are normalized, top-left origin, and live in the straightened frame. A positive straighten angle rotates clockwise on screen. `CropGeometry` keeps crops inside the rotated image.

**Rendering.** One recipe, `ImagePipeline.render`, serves the preview (`PreviewRenderer` actor), thumbnails (`Thumbnails`) and export (`Exporter`). Preview and export must match, so changes belong in the shared path.

1. `SourceImage` wraps one decode and is not thread-safe.
   - DNGs use `CIRAWFilter` with `boostAmount = 0` and `extendedDynamicRangeAmount = 2`. That gives scene-linear data with highlight headroom above 1.0. White balance is applied in the RAW filter. Exposure is a separate uncapped linear gain (`CIExposureAdjust`).
   - The decode size follows the crop, so tight crops aren't upscaled in the preview.
2. `ToneMapping.raw` maps scene-linear values to display.
   - Shadows and midtones follow a curve measured from Core Image's default RAW rendering, so the default look matches Apple's. Above that is a long highlight shoulder.
   - The curve is applied to the brightest channel with RGB scaled by the same ratio, so hues are preserved. Colors blend toward white only in the shoulder.
   - Highlights for RAW is folded into this curve. It reshapes tones only between a fixed pivot and the image's brightest level, which is measured on a 512px downsample and cached per white balance. Midtones and white stay fixed.
3. `ImagePipeline.applyTone` handles contrast, shadows, vibrance and saturation. It also handles Highlights for JPEGs only; RAW passes `highlights = 0`.
4. `applyGeometry` applies straighten, then crop, in Core Image's y-up coordinates.

JPEG sources skip the RAW-specific steps. They use `CITemperatureAndTint` for white balance, and a gentle highlight shoulder only when exposure is raised.

**Thumbnails and export.**
- Thumbnails show the file's embedded preview first. Edited photos are re-rendered through the pipeline one at a time, because full RAW decodes don't parallelize and are memory heavy.
- Export runs jobs sequentially in `Task.detached`. It writes sRGB JPEGs with a whitelisted subset of the original EXIF/GPS/TIFF metadata and orientation 1.

## Decisions to preserve

- RAW decoding uses Apple's camera profile (the default `CIRAWFilter` decoder version). The DNG-embedded profile (`*.dng` decoder versions, e.g. Leica "PROFILE M11") was tried and reverted: it was 3–5× slower to open and export.
- Responsiveness matters more than matching Lightroom exactly. Benchmark rendering changes old-vs-new, alternating the order to avoid cold-file-cache bias, and report the cost.
- Single-key menu shortcuts (←/→, G, E, R, `\`) are disabled while a sheet is shown.
