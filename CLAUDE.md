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
- Drive the harness from a `Task { @MainActor in … }` that waits with `Task.sleep`. Pumping `RunLoop` inside `DispatchQueue.main.async` never runs the model's main-actor tasks.
- Synthetic drags and scroll-wheel events didn't reach the zoomed `ScrollView`. To pan at 100%, find its `NSScrollView` and move the clip view (`contentView.scroll(to:)` plus `reflectScrolledClipView`), kept within the document.
- `xcrun xctrace record --template 'Time Profiler' --launch -- <harness>` profiles a harness run; `xctrace export` gives the samples as XML.

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
- preview rendering (see Loading and editing photos) and the thumbnail queue
- debounced sidecar saves, flushed (`flushSaves()`) on folder change, window close and app termination

`SourceFolders` manages the sidebar. Root folders are persisted as security-scoped bookmarks. Subfolders are listed lazily on expand. Roots on disconnected volumes are kept as unavailable and re-checked on mount, unmount and app activation. Folder URLs are compared after `SourceFolders.normalized(_:)`, because `URL` equality treats trailing-slash differences as unequal.

**Edits.** `EditSettings` is the whole per-photo edit. It is written by `Sidecar` to `<base>.edit.json` next to the original. The sidecar is deleted when settings return to default. When a DNG and a JPG share a base name, the JPG uses `<name>.JPG.edit.json`. Decoding clamps every value to its slider range. Crop rects are normalized, top-left origin, and live in the straightened frame. A positive straighten angle rotates clockwise on screen. `CropGeometry` keeps crops inside the rotated image.

**Rendering.** One recipe, `ImagePipeline.render`, serves the preview (`PreviewRenderer` actor), thumbnails (`Thumbnails`) and export (`Exporter`). Preview and export must match, so changes belong in the shared path. It takes the `CIContext` that will render the result, which also renders the local tone coefficients.

1. `SourceImage` wraps one decode and is not thread-safe.
   - DNGs use `CIRAWFilter` with `boostAmount = 0` and `extendedDynamicRangeAmount = 2`. That gives scene-linear data with highlight headroom above 1.0. White balance is applied in the RAW filter.
   - The decode size follows the crop, so tight crops aren't upscaled in the preview.
2. `ToneMapping` builds one lookup table per combination of exposure and Contrast. The `rgbTone` Metal kernel applies it the way Adobe's DNG SDK does (`RefBaselineRGBTone`): largest and smallest channels through the curve, middle channel interpolated. That preserves hue, while saturation follows the curve's slope.
   - Shadows and midtones follow a curve measured from Core Image's default RAW rendering, which matches Adobe's ACR3 default within one 8-bit level. A shoulder then reaches display white exactly at a fixed scene white, `ToneMapping.sceneWhite`.
   - Scene white is 6.0, which covers the highlight headroom seen in M11 files; clipped areas render at 249–254. A per-image measured white point was tried and rejected: it cost about 0.12 s per photo opened or exported.
   - Positive exposure scales the image and white point together. Negative exposure uses Adobe's white-preserving curve.
   - Contrast is an S-curve in gamma space around mid-gray, folded into the same table.
3. Highlights and Shadows are local: before the curve, `rgbToneLocal` multiplies each pixel by 2^Δ, where Δ depends on an edge-aware local average of log2 luminance. Regions move as a whole, so detail keeps its contrast, and all channels get the same gain, so hue is kept. Design and measurements are in `research.md` appendix B.
   - The average is a self-guided filter (`LocalTone`) run at 512 px. The kernel samples its coefficients (a, b) bilinearly and combines them with full-resolution luminance (`a · L + b`), so it follows edges at full resolution. It maps coordinates itself: upscaling the coefficient image with a transform made Core Image render it at full size every time, about 45 ms per slider step at 100%.
   - The coefficients depend only on the photo and its white balance, not on exposure or the two sliders. `SourceImage` caches them per white balance. They are computed from a fixed 1024 px decode (the RAW filter's scale changes for a moment), so preview, thumbnails, 100% tiles and export get the same ones. Never compute them inside a tile render: their region of interest is the whole image.
   - The kernel computes Δ itself: Highlights −100 halves the distance of bright regions above mid gray (after exposure), in stops; Shadows +100 halves it for dark regions below, up to 2 stops.
   - With both at 0, the plain `rgbTone` kernel runs and nothing else is computed.
4. `ImagePipeline.applyColor` handles vibrance and saturation.
5. `applyGeometry` applies straighten, then crop, in Core Image's y-up coordinates.

JPEG sources use `CITemperatureAndTint` for white balance and the same kernels with a display-referred table: exposure (with a shoulder that reaches white when raised) and Contrast, plus the same local Highlights and Shadows (coefficients from a 1024 px decode of the JPEG). With no adjustments they pass through untouched.

`research.md` surveys how Adobe, Apple, darktable and RawTherapee design these curves, with measurements.

**Loading and editing photos.** Opening a 60 MP M11 DNG takes about 0.8 s: 0.1 s to create the `CIRAWFilter`, 0.6 s of single-threaded decompression on the CPU, and 0.15 s of demosaicing on the GPU. The decompressed RAW stays in the `CIRAWFilter`, so later renders of the same `SourceImage`, in any context or at any scale, cost only the GPU part. A `CIContext` runs one render at a time, and a second context costs up to 2 GB.
- `PreviewRenderer` keeps 5 decoded sources (about 190 MB each). Its `prefetch` decodes a photo and renders its preview on a separate low-priority context without caching intermediates, then hands the source to the actor. Prefetching doesn't hold up renders of the photo being edited.
- `LibraryModel` keeps a small preview cache (one entry per photo and kind, with or without crop), keyed by settings, pixel size and color space. Photos next to the active one in the loupe, or the selected one in the grid (after 0.3 s), are prefetched into it once the active photo has rendered, so stepping through photos shows them at once. Cached previews also make `\` and undo instant. After showing a cached preview, the photo is rendered again in the preview's context while nothing waits on it, so the first slider step is fast.
- Until an unedited RAW photo has rendered, the loupe shows its embedded camera JPEG at screen size (`Thumbnails.screenPreview`, about 0.15 s), not the small thumbnail. Edited photos show their thumbnail, which has the edits.
- When photos are stepped through faster than every 0.25 s, decoding waits until stepping pauses for 0.2 s. A decode can't be stopped, so decoding each photo passed would hold up the one the user stops at.
- Preview renders run in a loop off the main actor that takes the newest request from `PreviewQueue`. A render therefore starts as soon as an edit asks for it, not after the main actor has updated the views for that edit, which used to add 5–25 ms per slider step.
- `Photo.isEdited` is stored and changes only when it flips. Menus, the grid and the filmstrip read it, so a slider step doesn't update them.

**100% zoom.** Clicking the loupe image or pressing Z toggles `LibraryModel.zoom`. Switching photos while zoomed stays at 100% at the same relative position (`zoomCenter`), for comparing focus across a burst. The zoomed view is a `ScrollView` sized to the full-resolution output. The fit preview is stretched underneath as a placeholder, and on top `PreviewRenderer.renderDetail` renders full-resolution pieces (`LibraryModel.detail`). While zoomed, edits re-render only at 100%; the fit preview is refreshed on exit. Rendering both sizes at once would flip the shared RAW decoder's scale back and forth.
- An edit renders the visible area plus a margin as one piece, replacing the others. The margin is up to 256 px, kept within a 14 MP region budget. Core Image keeps the decoded RAW cached only for regions up to about 16 MP. Past that, every edit decodes again: on a 5K window, about 150 ms per edit instead of about 10 ms.
- A pan adds 512 px tiles where the rendered pieces don't cover the visible area plus 256 px, then tiles ahead of the pan (up to two). A column of tiles takes about 15 ms; re-rendering the whole area took about 80 ms. A tile counts as covered when the union of the pieces covers it. Tiles and whole-area renders match within one 8-bit level, so there are no seams.
- Zooming in or out from a click or Z animates with an overlay (`ZoomTransitionView`) that scales the preview between its fit frame and its 100% frame, then reveals the real view. The two views can't animate into each other: the scroll view only draws what's visible at 100%. Switching photos while zoomed doesn't animate. The overlay uses a timing curve, not a spring: a spring's completion fires in its tail, so removing the overlay then shows a jump.
- The scroll view extends under the sidebar, inspector and toolbar as content insets. `scrollTo(point:)` takes the top-left of the visible area, which is `contentOffset` plus the leading and top insets, not `visibleRect.origin`.

**Showing rendered images.** The preview and 100% detail go through `ImagePipeline.bitmap`, not `CIContext.createCGImage`:
- `createCGImage` sometimes returns a lazily rendered image, which moves the render onto the main thread when the image is first drawn.
- `bitmap` renders on the actor, in the screen's color space and in BGRA. Otherwise Core Animation converts every pixel on the CPU at commit while the main thread waits, about 40 ms for 14 MP.

**Thumbnails and export.**
- Thumbnails show the file's embedded preview first. Edited photos are re-rendered through the pipeline one at a time: renders on one context don't run in parallel, and another context would cost up to 2 GB.
- A photo's thumbnail is refreshed from its preview render once preview renders pause for 0.3 s, also after moving on to another photo. Refreshing it after each render made every other slider step wait about 30 ms for the downscale.
- Export runs jobs sequentially in `Task.detached`. It writes sRGB JPEGs with a whitelisted subset of the original EXIF/GPS/TIFF metadata and orientation 1.

**UI conventions.** Shared controls live in `Views/Controls.swift`.
- The chrome stays neutral so it doesn't compete with the photo. The accent color, a mid gray (`AccentColor` asset, set as the global accent in build settings), marks selection and primary actions; it stays dark enough for the white text the system draws on sidebar highlights and buttons. Thumbnail selection rings use the lighter `Color.selectionRing`. Values are drawn in white.
- Adjustments use `TrackSlider`, not `Slider`. Its fill starts at the default value, so an untouched adjustment shows no fill and a changed one shows how far it moved. White balance tracks show their color scale instead of a fill.
- Inspector sections match the Copy Adjustments groups (Crop, Light, White Balance, Color). Each adjustment, and the crop, shows a reset icon after its name only when it has changed; section headers have none. The photo's Reset is in the header next to its name. Copy and Paste are menu commands only (⌘C, ⌘V), with no inspector buttons.
- Floating labels over the photo use `canvasLabel()` (glass capsule).

**Interactions.** Where Lightroom and Photos agree, Silver follows them.
- Every keyboard shortcut is a menu command, so it shows in the menu bar and works regardless of focus. Commands that toggle ignore key auto-repeat (`ignoringRepeats`).
- Paste, Reset and Export commands act on all selected photos, and their labels give the count when it's more than one. In the inspector, Reset and the reset icons act on the photo shown.
- Context-menu commands act on the selection when the clicked photo is in it, otherwise on just that photo (`contextTargets`), without changing the selection.
- In the loupe, a click toggles 100% and a double-click returns to the grid. The click waits 0.25 s for a second click itself (`PreviewCanvas.click`), not via `onTapGesture(count: 2)`, which holds a single tap back about 0.35 s. A slower double-click still reaches the grid by its `clickCount`, after the first click has acted.
- `\` toggles the original on a tap and shows it only while held on a longer press. A key-up monitor in `AppDelegate` ends the hold, since menu commands only see key presses.
- Values can be typed after clicking them in the inspector. While a field has the keyboard, `valueEditor` is set and single-key shortcuts and the crop's Return/Escape buttons are off, and ⌘C/⌘V copy and paste the field's text instead of adjustments.
- In the crop editor, dragging outside the crop rotates (the cursor curves around the side or corner of the crop the pointer is at), ⌘-drag draws a level line, ⇧ keeps proportions, ⌥ resizes around the center, and double-clicking inside finishes. Modifiers come from `NSApp.currentEvent`, the event being handled, not the live keyboard state.

## Decisions to preserve

- RAW decoding uses Apple's camera profile (the default `CIRAWFilter` decoder version). The DNG-embedded profile (`*.dng` decoder versions, e.g. Leica "PROFILE M11") was tried and reverted: it was 3–5× slower to open and export.
- Responsiveness matters more than matching Lightroom exactly. Benchmark rendering changes old-vs-new, alternating the order to avoid cold-file-cache bias, and report the cost.
- Single-key menu shortcuts (arrows, Space, G, E, R, X, Z, `\`) are disabled while a sheet is shown or a value is being typed (`allowsSingleKeyShortcuts`).
