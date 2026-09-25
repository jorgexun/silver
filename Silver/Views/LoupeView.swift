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

    /// Scroll position where a pan of the zoomed view started; nil when not panning.
    @State private var panStart: CGPoint?

    var body: some View {
        let preview = library.preview?.photoID == photo.id ? library.preview : nil
        let image = preview?.image ?? photo.thumbnail
        let isZoomed = library.zoom?.photoID == photo.id
        Group {
            if let zoom = library.zoom, isZoomed {
                ZoomedCanvas(zoom: zoom, base: image, dragStart: $panStart)
                    .id(zoom.photoID)  // Fresh scroll state for each photo.
            } else {
                fitCanvas(image: image, isLoading: preview == nil)
            }
        }
        // On the container, so the cursor follows a click that zooms in or out.
        .cursor(cursor(isZoomed: isZoomed, hasImage: image != nil))
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

    private func cursor(isZoomed: Bool, hasImage: Bool) -> CanvasCursor {
        if isZoomed { return panStart == nil ? .openHand : .closedHand }
        return hasImage ? .zoomIn : .arrow
    }

    private func fitCanvas(image: CGImage?, isLoading: Bool) -> some View {
        GeometryReader { geometry in
            let padding: CGFloat = 28
            let frame = image.map { fitRect(CGSize(width: $0.width, height: $0.height), in: geometry.size, padding: padding) }
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .padding(padding)
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let frame, frame.width > 0, frame.height > 0 else { return }
                let focus = CGPoint(
                    x: min(max((location.x - frame.minX) / frame.width, 0), 1),
                    y: min(max((location.y - frame.minY) / frame.height, 0), 1)
                )
                let anchor = CGPoint(x: location.x / geometry.size.width, y: location.y / geometry.size.height)
                library.toggleZoom(focus: focus, anchor: anchor)
            }
        }
    }
}

/// The photo at 100%: one image pixel per screen pixel. The fit preview, enlarged, fills in
/// until the visible area has been rendered at full resolution on top of it.
private struct ZoomedCanvas: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.displayScale) private var displayScale
    let zoom: ZoomState
    let base: CGImage?
    @Binding var dragStart: CGPoint?

    @State private var position = ScrollPosition()
    @State private var scroll = ScrollTracker()
    @State private var didScrollToFocus = false

    var body: some View {
        GeometryReader { geometry in
            if let fullSize = library.zoomFullSize {
                let content = CGSize(width: fullSize.width / displayScale, height: fullSize.height / displayScale)
                // Center images smaller than the window.
                let inset = CGSize(
                    width: max((geometry.size.width - content.width) / 2, 0),
                    height: max((geometry.size.height - content.height) / 2, 0)
                )
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        if let base {
                            Image(decorative: base, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: content.width, height: content.height)
                        }
                        if let detail = library.detail, detail.photoID == zoom.photoID {
                            Image(decorative: detail.image, scale: displayScale)
                                .interpolation(.none)
                                .offset(x: detail.rect.minX / displayScale, y: detail.rect.minY / displayScale)
                        }
                    }
                    .frame(width: content.width, height: content.height, alignment: .topLeading)
                    .clipped()
                    .padding(.horizontal, inset.width)
                    .padding(.vertical, inset.height)
                    .contentShape(Rectangle())
                    .onTapGesture { library.exitZoom() }
                    .gesture(
                        // Global coordinates: the content moves while it scrolls, so local
                        // translations would feed back into the scroll position.
                        DragGesture(minimumDistance: 3, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? scroll.origin
                                dragStart = start
                                position.scrollTo(point: CGPoint(x: start.x - value.translation.width, y: start.y - value.translation.height))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                }
                .scrollIndicators(.automatic)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGRect.self, of: Self.visibleArea) { _, rect in
                    scroll.origin = rect.origin
                    let visible = CGRect(
                        x: (rect.minX - inset.width) * displayScale,
                        y: (rect.minY - inset.height) * displayScale,
                        width: rect.width * displayScale,
                        height: rect.height * displayScale
                    )
                    library.setZoomViewport(visible)
                }
                .onAppear {
                    guard !didScrollToFocus else { return }
                    didScrollToFocus = true
                    // Keep the clicked point under the cursor.
                    position.scrollTo(point: CGPoint(
                        x: zoom.focus.x * content.width + inset.width - zoom.anchor.x * geometry.size.width,
                        y: zoom.focus.y * content.height + inset.height - zoom.anchor.y * geometry.size.height
                    ))
                }
            } else {
                ZStack {
                    if let base {
                        Image(decorative: base, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(28)
                    }
                    ProgressView().controlSize(.small)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    /// The area not covered by the sidebar, inspector or toolbar, in content coordinates. Its
    /// origin is the point `scrollTo(point:)` takes; `visibleRect` also covers the insets.
    private static func visibleArea(_ geometry: ScrollGeometry) -> CGRect {
        CGRect(
            x: geometry.contentOffset.x + geometry.contentInsets.leading,
            y: geometry.contentOffset.y + geometry.contentInsets.top,
            width: geometry.containerSize.width,
            height: geometry.containerSize.height
        )
    }
}

/// Scroll position read at the start of a drag. Not view state: it changes on every frame
/// of a scroll, and nothing is drawn from it.
private final class ScrollTracker {
    var origin: CGPoint = .zero
}

private enum CanvasCursor: Equatable {
    case arrow, zoomIn, openHand, closedHand
    case resize(FrameResizePosition)

    var style: PointerStyle {
        switch self {
        case .arrow: .default
        case .zoomIn: .zoomIn
        case .openHand: .grabIdle
        case .closedHand: .grabActive
        case .resize(let position): .frameResize(position: position)
        }
    }

    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .zoomIn: .zoomIn
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resize(let position): .frameResize(position: Self.appKitPosition(position), directions: .all)
        }
    }

    private static func appKitPosition(_ position: FrameResizePosition) -> NSCursor.FrameResizePosition {
        switch position {
        case .top: .top
        case .leading: .left
        case .bottom: .bottom
        case .trailing: .right
        case .topLeading: .topLeft
        case .topTrailing: .topRight
        case .bottomLeading: .bottomLeft
        case .bottomTrailing: .bottomRight
        }
    }
}

extension View {
    /// Shows `cursor` over this view. `pointerStyle` alone misses drags, state changes and exits
    /// (see CLAUDE.md), so the cursor is also set directly and reset to the arrow on exit.
    fileprivate func cursor(_ cursor: CanvasCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}

private struct CursorModifier: ViewModifier {
    let cursor: CanvasCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .pointerStyle(cursor.style)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    cursor.nsCursor.set()
                case .ended:
                    isHovering = false
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: cursor) {
                if isHovering { cursor.nsCursor.set() }
            }
    }
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

    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }
}

/// What a pointer grabs in the crop editor.
private enum CropTarget: Equatable {
    case move
    case resize(CropHandle)

    /// Corners and edges within a few points of the crop outline, then the inside of the crop;
    /// nil outside it.
    init?(at point: CGPoint, in frame: CGRect) {
        let cornerReach: CGFloat = 12
        let edgeReach: CGFloat = 8
        // For a narrow crop, the nearer side wins.
        let left = abs(point.x - frame.minX), right = abs(point.x - frame.maxX)
        let top = abs(point.y - frame.minY), bottom = abs(point.y - frame.maxY)
        let nearLeft = left <= right
        let nearTop = top <= bottom
        let dx = min(left, right), dy = min(top, bottom)

        if dx <= cornerReach, dy <= cornerReach {
            self = .resize(nearTop ? (nearLeft ? .topLeft : .topRight) : (nearLeft ? .bottomLeft : .bottomRight))
        } else if dx <= edgeReach, point.y > frame.minY, point.y < frame.maxY {
            self = .resize(nearLeft ? .left : .right)
        } else if dy <= edgeReach, point.x > frame.minX, point.x < frame.maxX {
            self = .resize(nearTop ? .top : .bottom)
        } else if frame.contains(point) {
            self = .move
        } else {
            return nil
        }
    }
}

struct CropEditorView: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo
    let image: CGImage?

    /// What the current drag grabbed and the crop when it started; drags starting outside the
    /// crop do nothing.
    @State private var drag: (target: CropTarget, start: CropRect)?
    @State private var hover: CropTarget?

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
                .stroke(Color.white.opacity(drag != nil ? 0.55 : 0.25), lineWidth: 0.5)
                .allowsHitTesting(false)

            Rectangle()
                .path(in: cropFrame)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .allowsHitTesting(false)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(handle.point(in: cropFrame))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                hover = CropTarget(at: point, in: cropFrame)
            } else {
                hover = nil
            }
        }
        .gesture(dragGesture(cropFrame: cropFrame, box: box, imageSize: imageSize))
        .cursor(cursor)
    }

    /// A drag keeps the cursor of what it grabbed, even when the pointer moves off it.
    private var cursor: CanvasCursor {
        let target = drag?.target ?? hover
        switch target {
        case .move: return drag == nil ? .openHand : .closedHand
        case .resize(let handle): return .resize(handle.resizePosition)
        case nil: return .arrow
        }
    }

    private func handleView(_ handle: CropHandle) -> some View {
        Group {
            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: [.top, .bottom].contains(handle) ? 22 : 5, height: [.top, .bottom].contains(handle) ? 5 : 22)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 1)
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

    private func dragGesture(cropFrame: CGRect, box: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let settings = photo.settings
                if drag == nil, let target = CropTarget(at: value.startLocation, in: cropFrame) {
                    drag = (target, settings.crop)
                }
                guard let drag else { return }
                let start = drag.start
                let dx = value.translation.width / box.width
                let dy = value.translation.height / box.height
                let normalizedAspect = CropGeometry.pixelAspect(for: settings.aspectRatio, matching: start, imageSize: imageSize)
                    .map { $0 / Double(imageSize.width / imageSize.height) }
                let proposal = proposedRect(from: start, target: drag.target, dx: dx, dy: dy, aspect: normalizedAspect)
                let rect = CropGeometry.constrained(from: settings.crop, to: proposal, angle: settings.straighten, imageSize: imageSize)
                library.setCrop(rect)
            }
            .onEnded { value in
                drag = nil
                hover = CropTarget(at: value.location, in: cropFrame)
            }
    }

    private func proposedRect(from start: CropRect, target: CropTarget, dx: Double, dy: Double, aspect: Double?) -> CropRect {
        guard case .resize(let handle) = target else {
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

        if let aspect {
            var width = maxX - minX
            var height = maxY - minY
            // An edge keeps the ratio by resizing the other axis about the crop's center.
            if handle == .left || handle == .right {
                return CropRect(centerX: (minX + maxX) / 2, centerY: start.midY, width: width, height: width / aspect)
            }
            if handle == .top || handle == .bottom {
                return CropRect(centerX: start.midX, centerY: (minY + maxY) / 2, width: height * aspect, height: height)
            }
            // A corner grows the shorter side to match, anchored at the opposite corner.
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
}
