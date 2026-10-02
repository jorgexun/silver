# Silver

A minimal native macOS app for a personal RAW-to-JPEG workflow: browse folders of DNGs (Leica M11/Q2) and JPEGs, make basic light, color and crop edits, and batch export sRGB JPEGs for Apple Photos.

- Edits are non-destructive and stored next to each photo as `<name>.edit.json`.
- Light: exposure, contrast, and local Highlights and Shadows. Color: white balance, vibrance, saturation. Geometry: crop and straighten.
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

- `prd.md`: product spec (Chinese)
- `research.md`: tone curve and Highlights/Shadows research, with measurements (Chinese)
- `CLAUDE.md`: architecture and development notes
