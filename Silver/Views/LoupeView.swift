import SwiftUI

struct LoupeView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.canvas
                if let photo = library.activePhoto {
                    if library.isCropping {
                        CropEditorView(photo: photo, image: uncroppedPreview(for: photo))
                    } else {
                        PreviewCanvas(photo: photo)
                    }
                }
            }
            .clipped()

            Divider()
            FilmstripView()
                .frame(height: 88)
        }
    }

    private func uncroppedPreview(for photo: Photo) -> CGImage? {
        guard let preview = library.preview, preview.photoID == photo.id, !preview.hasGeometry else { return nil }
        return preview.image
    }
}

private struct PreviewCanvas: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        let preview = library.preview?.photoID == photo.id ? library.preview : nil
        ZStack {
            if let image = preview?.image ?? photo.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .padding(28)
            }
            if preview == nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .overlay(alignment: .top) {
            if library.showOriginal {
                Text("Original")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 10)
            }
        }
    }
}

// MARK: - Crop editor

private enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    func point(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }
}

struct CropEditorView: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo
    let image: CGImage?

    @State private var dragStart: CropRect?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            if let imageSize = photo.geometrySize {
                editor(viewSize: geometry.size, imageSize: imageSize)
            }
        }
    }

    @ViewBuilder
    private func editor(viewSize: CGSize, imageSize: CGSize) -> some View {
        let settings = photo.settings
        let box = fitRect(imageSize, in: viewSize, padding: 36)
        let crop = settings.crop
        let cropFrame = CGRect(
            x: box.minX + crop.x * box.width,
            y: box.minY + crop.y * box.height,
            width: crop.width * box.width,
            height: crop.height * box.height
        )
        let locked = settings.aspectRatio != .free

        ZStack(alignment: .topLeading) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Rectangle().fill(Color.white.opacity(0.05))
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: box.width, height: box.height)
            .rotationEffect(.degrees(settings.straighten))
            .position(x: box.midX, y: box.midY)

            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewSize))
                path.addRect(cropFrame)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            thirdsGrid(in: cropFrame)
                .stroke(Color.white.opacity(isDragging ? 0.55 : 0.25), lineWidth: 0.5)
                .allowsHitTesting(false)

            Rectangle()
                .path(in: cropFrame)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .allowsHitTesting(false)

            // Drag inside the crop to move it.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: max(cropFrame.width - 24, 1), height: max(cropFrame.height - 24, 1))
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(dragGesture(handle: nil, box: box, imageSize: imageSize))
                .pointerStyle(isDragging ? .grabActive : .grabIdle)

            ForEach(CropHandle.allCases.filter { $0.isCorner || !locked }, id: \.self) { handle in
                handleView(handle)
                    .position(handle.point(in: cropFrame))
                    .gesture(dragGesture(handle: handle, box: box, imageSize: imageSize))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private func handleView(_ handle: CropHandle) -> some View {
        ZStack {
            Color.clear.frame(width: 26, height: 26).contentShape(Rectangle())
            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: [.top, .bottom].contains(handle) ? 22 : 5, height: [.top, .bottom].contains(handle) ? 5 : 22)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
        }
    }

    private func thirdsGrid(in rect: CGRect) -> Path {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }

    private func dragGesture(handle: CropHandle?, box: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let settings = photo.settings
                let start = dragStart ?? settings.crop
                if dragStart == nil {
                    dragStart = start
                    isDragging = true
                }
                let dx = value.translation.width / box.width
                let dy = value.translation.height / box.height
                let normalizedAspect = CropGeometry.pixelAspect(for: settings.aspectRatio, matching: start, imageSize: imageSize)
                    .map { $0 / Double(imageSize.width / imageSize.height) }
                let proposal = proposedRect(from: start, handle: handle, dx: dx, dy: dy, aspect: normalizedAspect)
                let rect = CropGeometry.constrained(from: settings.crop, to: proposal, angle: settings.straighten, imageSize: imageSize)
                library.setCrop(rect)
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false
            }
    }

    private func proposedRect(from start: CropRect, handle: CropHandle?, dx: Double, dy: Double, aspect: Double?) -> CropRect {
        guard let handle else {
            let x = min(max(start.x + dx, 0), 1 - start.width)
            let y = min(max(start.y + dy, 0), 1 - start.height)
            return CropRect(x: x, y: y, width: start.width, height: start.height)
        }

        let minSize = CropGeometry.minimumSize
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.movesLeft { minX = min(max(start.minX + dx, 0), maxX - minSize) }
        if handle.movesRight { maxX = max(min(start.maxX + dx, 1), minX + minSize) }
        if handle.movesTop { minY = min(max(start.minY + dy, 0), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(start.maxY + dy, 1), minY + minSize) }

        if let aspect, handle.isCorner {
            // Grow the shorter side to match the ratio, anchored at the opposite corner.
            var width = maxX - minX
            var height = maxY - minY
            if width / height > aspect {
                height = width / aspect
            } else {
                width = height * aspect
            }
            if handle.movesLeft { minX = maxX - width } else { maxX = minX + width }
            if handle.movesTop { minY = maxY - height } else { maxY = minY + height }
        }
        return CropRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    private func fitRect(_ size: CGSize, in container: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(width: max(container.width - padding * 2, 1), height: max(container.height - padding * 2, 1))
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (container.width - fitted.width) / 2,
            y: (container.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
