# Silver

A minimal native macOS app for a personal RAW-to-JPEG workflow: browse folders of DNGs (Leica M11/Q2) and JPEGs, make basic light, color and crop edits, and batch export sRGB JPEGs to a folder or Apple Photos.

- Edits are non-destructive and stored next to each photo as `<name>.edit.json`.
- Light: exposure, contrast, Whites and Blacks, and local Highlights and Shadows. Color: white balance, vibrance, saturation. Geometry: crop and straighten.
- Copy and paste adjustments across photos, and reset or export the whole selection at once.
- Zoom from fit to 400% to check focus, keeping the same spot while stepping through a burst.
- Export runs in the background, to a folder, the Photos library, or both, keeping a subset of the original EXIF and GPS metadata.
- One rendering pipeline (Core Image and Metal) serves the preview, thumbnails and export, so what you see is what you export.

## Requirements

- macOS 27 and Xcode with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`)

## Build

```sh
xcodebuild -project Silver.xcodeproj -scheme Silver -configuration Debug \
  -derivedDataPath /tmp/SilverDerivedData build
open /tmp/SilverDerivedData/Build/Products/Debug/Silver.app
```

## Docs

`CLAUDE.md` has the architecture, rendering pipeline and development notes.
