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

Building needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`): `Imaging/ToneKernels.metal` holds Core Image kernels, compiled via the target's `MTL_COMPILER_FLAGS`/`MTLLINKER_FLAGS = -fcikernel` into `default.metallib`.

There is no test target and no linter. The imaging and model code is `nonisolated` and has no UI dependencies, so it is tested with throwaway `swiftc` harnesses against real DNGs (test photos are not in the repo):

```sh
cd Silver
swiftc -O -o /tmp/harness \
  Model/EditSettings.swift Imaging/CropGeometry.swift Imaging/ImagePipeline.swift Imaging/ToneMapping.swift \
  Imaging/Thumbnails.swift Model/Exporter.swift Model/Sidecar.swift \
  /path/to/main.swift            # add Model/Bookmarks.swift Model/SourceFolders.swift for sidebar logic
```

The harness file must be named `main.swift` for top-level code (don't pass `-parse-as-library`). Before rendering, it must set `ToneMapping.metalLibraryURL` to a built `default.metallib` (e.g. from the app bundle in DerivedData); otherwise tone mapping is skipped. When comparing renders, compare 8-bit rendered pixels: `CIAreaAverage` over large cropped extents gives misleading results.

Views can be checked the same way, without a display:
- Compile every file except `SilverApp.swift` with Xcode's Swift flags: `-default-isolation MainActor` and the `-enable-upcoming-feature` list from the build log.
- Host `ContentView` in an `NSHostingView` (with `sceneBridgingOptions = [.toolbars, .title]` for the toolbar) and write `cacheDisplay(in:to:)` output to PNG.
- Mouse and key events sent with `window.sendEvent` drive SwiftUI gestures and text fields. AppKit tracking loops, such as split view dividers, need the drag and mouse-up queued with `NSApp.postEvent` first.
- Events sent with `window.sendEvent` don't set `NSApp.currentEvent`, where the crop editor reads modifier keys from. Queue those drags with `NSApp.postEvent` to test ⇧, ⌥ and ⌘.
- Menu commands aren't in the harness. Test them on the app itself with `CGEvent.postToPid`, which reaches a background instance without touching the frontmost app.
- Glass and sidebar vibrancy don't render this way.

## Project setup gotchas

- The target uses file-system-synchronized groups: any file under `Silver/` is compiled automatically, with no `project.pbxproj` edit needed.
- Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency. Everything is main-actor unless marked `nonisolated`, and `nonisolated async` functions run on the caller's actor. Heavy work therefore goes through `Task.detached` or the `PreviewRenderer` actor, and value types used off the main actor are declared `nonisolated`.
- A `MagnifyGesture` on the same view as a `DragGesture` holds back the drag's updates until the mouse is released, so a pan jumps at the end instead of following the pointer. The zoomed view's pinch is therefore on the scroll view, not on the content with the pan.
- Loupe cursors use the `cursor(_:)` modifier in `LoupeView.swift`, not `pointerStyle` alone. `pointerStyle` misses state changes under a still pointer, changes during a drag, and exits into the sidebar and toolbar, which set no cursor of their own.
- App Sandbox: user-selected files are read-write (needed for sidecars and export). `Silver.entitlements` adds app-scoped security bookmarks and is merged with the build-setting entitlements.

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
   - DNGs use `CIRAWFilter` with `boostAmount = 0` and `extendedDynamicRangeAmount = 2`. That gives scene-linear data with highlight headroom above 1.0. White balance is applied in the RAW filter.
   - The decode size follows the crop, so tight crops aren't upscaled in the preview.
2. `ToneMapping` builds one lookup table per combination of exposure, Highlights and Contrast. The `rgbTone` Metal kernel applies it the way Adobe's DNG SDK does (`RefBaselineRGBTone`): largest and smallest channels through the curve, middle channel interpolated. That preserves hue, while saturation follows the curve's slope.
   - Shadows and midtones follow a curve measured from Core Image's default RAW rendering, which matches Adobe's ACR3 default within one 8-bit level. A shoulder then reaches display white exactly at a fixed scene white, `ToneMapping.sceneWhite`.
   - Scene white is 6.0, which covers the highlight headroom seen in M11 files; clipped areas render at 249–254. A per-image measured white point was tried and rejected: it cost about 0.12 s per photo opened or exported.
   - Positive exposure scales the image and white point together. Negative exposure uses Adobe's white-preserving curve.
   - Highlights reshapes tones between a pivot (0.3) and white in log space, leaving both ends fixed.
   - Contrast is an S-curve in gamma space around mid-gray. Both Highlights and Contrast are folded into the same table.
3. `ImagePipeline.applyTone` handles shadows (`CIHighlightShadowAdjust`, global), vibrance and saturation, plus negative Highlights for JPEGs only.
4. `applyGeometry` applies straighten, then crop, in Core Image's y-up coordinates.

JPEG sources use `CITemperatureAndTint` for white balance and the same kernel with a display-referred table: exposure (with a soft shoulder when raised), positive Highlights, and Contrast. With no adjustments they pass through untouched.

`research.md` surveys how Adobe, Apple, darktable and RawTherapee design these curves, with measurements.

**100% zoom.** Clicking the loupe image or pressing Z toggles `LibraryModel.zoom`. Switching photos while zoomed stays at 100% at the same relative position (`zoomCenter`), for comparing focus across a burst. The zoomed view is a `ScrollView` sized to the full-resolution output. The fit preview is stretched underneath as a placeholder, and on top `PreviewRenderer.renderDetail` renders only the visible area (plus a margin) at full resolution. While zoomed, edits re-render just that area; the fit preview is refreshed on exit. Rendering both sizes at once would flip the shared RAW decoder's scale back and forth.
- The margin is up to 256 px, kept within a 14 MP region budget. Core Image keeps the decoded RAW cached only for regions up to about 16 MP. Past that, every edit decodes again: on a 5K window, about 150 ms per edit instead of about 10 ms.
- Zooming in or out from a click or Z animates with an overlay (`ZoomTransitionView`) that scales the preview between its fit frame and its 100% frame, then reveals the real view. The two views can't animate into each other: the scroll view only draws what's visible at 100%. Switching photos while zoomed doesn't animate. The overlay uses a timing curve, not a spring: a spring's completion fires in its tail, so removing the overlay then shows a jump.
- The scroll view extends under the sidebar, inspector and toolbar as content insets. `scrollTo(point:)` takes the top-left of the visible area, which is `contentOffset` plus the leading and top insets, not `visibleRect.origin`.

**Showing rendered images.** The preview and 100% detail go through `ImagePipeline.bitmap`, not `CIContext.createCGImage`:
- `createCGImage` sometimes returns a lazily rendered image, which moves the render onto the main thread when the image is first drawn.
- `bitmap` renders on the actor, in the screen's color space and in BGRA. Otherwise Core Animation converts every pixel on the CPU at commit while the main thread waits, about 40 ms for 14 MP.

**Thumbnails and export.**
- Thumbnails show the file's embedded preview first. Edited photos are re-rendered through the pipeline one at a time, because full RAW decodes don't parallelize and are memory heavy.
- The active photo's thumbnail is refreshed from the preview render once edits pause (no newer render pending), not on every step of a slider drag.
- Export runs jobs sequentially in `Task.detached`. It writes sRGB JPEGs with a whitelisted subset of the original EXIF/GPS/TIFF metadata and orientation 1.

**UI conventions.** Shared controls live in `Views/Controls.swift`.
- The chrome stays neutral so it doesn't compete with the photo. The accent color marks selection and primary actions; values are drawn in white.
- Adjustments use `TrackSlider`, not `Slider`. Its fill starts at the default value, so an untouched adjustment shows no fill and a changed one shows how far it moved. White balance tracks show their color scale instead of a fill.
- Inspector sections match the Copy Adjustments groups (Light, White Balance, Color, Crop). Each shows a reset button only when it has changes.
- Floating labels over the photo use `canvasLabel()` (glass capsule).

**Interactions.** Where Lightroom and Photos agree, Silver follows them.
- Every keyboard shortcut is a menu command, so it shows in the menu bar and works regardless of focus. Commands that toggle ignore key auto-repeat (`ignoringRepeats`).
- Paste, Reset and Export commands act on all selected photos, and their labels give the count when it's more than one. In the inspector, Paste does the same, while Reset and the section resets act on the photo shown.
- Context-menu commands act on the selection when the clicked photo is in it, otherwise on just that photo (`contextTargets`), without changing the selection.
- `\` toggles the original on a tap and shows it only while held on a longer press. A key-up monitor in `AppDelegate` ends the hold, since menu commands only see key presses.
- Values can be typed after clicking them in the inspector. While a field has the keyboard, `valueEditor` is set and single-key shortcuts and the crop's Return/Escape buttons are off.
- In the crop editor, dragging outside the crop rotates, ⌘-drag draws a level line, ⇧ keeps proportions, ⌥ resizes around the center, and double-clicking inside finishes. Modifiers come from `NSApp.currentEvent`, the event being handled, not the live keyboard state.

## Decisions to preserve

- RAW decoding uses Apple's camera profile (the default `CIRAWFilter` decoder version). The DNG-embedded profile (`*.dng` decoder versions, e.g. Leica "PROFILE M11") was tried and reverted: it was 3–5× slower to open and export.
- Responsiveness matters more than matching Lightroom exactly. Benchmark rendering changes old-vs-new, alternating the order to avoid cold-file-cache bias, and report the cost.
- Single-key menu shortcuts (arrows, Space, G, E, R, X, Z, `\`) are disabled while a sheet is shown or a value is being typed (`allowsSingleKeyShortcuts`).
