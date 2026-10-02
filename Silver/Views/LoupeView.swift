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
                .frame(height: FilmstripView.height)
        }
    }

    private func uncroppedPreview(for photo: Photo) -> CGImage? {
        guard let preview = library.preview, preview.photoID == photo.id, !preview.hasGeometry else { return nil }
        return preview.image
    }
}

private struct PreviewCanvas: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: Photo

    /// Scroll position where a pan of the zoomed view started; nil when not panning.
    @State private var panStart: CGPoint?
    @State private var zoomed = ZoomedTracker()
    /// Set when zooming in from the fit view, until the zoomed view knows where the image goes.
    @State private var animatesZoomIn = false
    @State private var transition: ZoomTransition?
    /// A single click waiting to see whether it becomes a double-click.
    @State private var pendingClick: Task<Void, Never>?

    var body: some View {
        let preview = library.preview?.photoID == photo.id ? library.preview : nil
        let placeholder = library.placeholder?.photoID == photo.id ? library.placeholder : nil
        let image = preview?.image ?? placeholder?.image ?? photo.thumbnail
        let isZoomed = library.zoom?.photoID == photo.id
        Group {
            if let zoom = library.zoom, isZoomed {
                ZoomedCanvas(zoom: zoom, base: image, dragStart: $panStart, tracker: zoomed, onClick: { click { library.exitZoom() } }) { frame in
                    guard animatesZoomIn else { return }
                    animatesZoomIn = false
                    transition = ZoomTransition(base: image, detail: [], frame: frame, zoomingIn: true)
                }
                .id(zoom.photoID)  // Fresh scroll state for each photo.
            } else {
                fitCanvas(image: image)
            }
        }
        .overlay {
            if let transition {
                ZoomTransitionView(transition: transition) {
                    if self.transition?.id == transition.id { self.transition = nil }
                }
                .id(transition.id)
            }
        }
        .onChange(of: isZoomed) { _, isZoomed in
            transition = nil
            if isZoomed {
                zoomed.detail = []
                animatesZoomIn = !reduceMotion
            } else if !reduceMotion, let frame = zoomed.frame {
                let detail = zoomed.detail.filter { $0.photoID == photo.id }
                transition = ZoomTransition(base: image, detail: detail, frame: frame, zoomingIn: false)
            }
        }
        .onDisappear { pendingClick?.cancel() }
        // On the container, so the cursor follows a click that zooms in or out.
        .cursor(cursor(isZoomed: isZoomed, hasImage: image != nil))
        .contextMenu { PhotoContextMenu(photo: photo) }
        .overlay(alignment: .top) {
            if library.showOriginal {
                Text("Original")
                    .canvasLabel()
                    .padding(.top, 12)
            }
        }
    }

    /// Runs `action` for a single click, once a double-click (back to the grid) is ruled out.
    /// Waits 0.25 s, not the 0.35 s a SwiftUI double-tap gesture holds back a single tap. A
    /// slower double-click still goes to the grid by its click count, after the single click acted.
    private func click(_ action: @escaping () -> Void) {
        pendingClick?.cancel()
        pendingClick = nil
        if let event = NSApp.currentEvent, event.clickCount >= 2 {
            library.viewMode = .grid
            return
        }
        pendingClick = Task {
            try? await Task.sleep(for: .seconds(min(NSEvent.doubleClickInterval, 0.25)))
            guard !Task.isCancelled else { return }
            pendingClick = nil
            action()
        }
    }

    private func cursor(isZoomed: Bool, hasImage: Bool) -> CanvasCursor {
        if isZoomed { return panStart == nil ? .openHand : .closedHand }
        return hasImage ? .zoomIn : .arrow
    }

    private func fitCanvas(image: CGImage?) -> some View {
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
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                click { zoom(at: location, frame: frame, canvas: geometry.size) }
            }
            // Pinching out zooms to 100% where the fingers are, as in Photos.
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                if value.magnification > 1.15 { zoom(at: value.startLocation, frame: frame, canvas: geometry.size) }
            })
        }
    }

    /// Zooms to 100% keeping the image point at `location` under it.
    private func zoom(at location: CGPoint, frame: CGRect?, canvas: CGSize) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        let focus = CGPoint(
            x: min(max((location.x - frame.minX) / frame.width, 0), 1),
            y: min(max((location.y - frame.minY) / frame.height, 0), 1)
        )
        let anchor = CGPoint(x: location.x / canvas.width, y: location.y / canvas.height)
        library.toggleZoom(focus: focus, anchor: anchor)
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
    let tracker: ZoomedTracker
    let onClick: () -> Void
    /// Called once the image's place at 100% is known, before it is first shown there.
    let onPlaced: (ZoomedFrame) -> Void

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
                        ForEach(library.detail.filter { $0.photoID == zoom.photoID }) { piece in
                            Image(decorative: piece.image, scale: displayScale)
                                .interpolation(.none)
                                .offset(x: piece.rect.minX / displayScale, y: piece.rect.minY / displayScale)
                        }
                    }
                    .frame(width: content.width, height: content.height, alignment: .topLeading)
                    .clipped()
                    .padding(.horizontal, inset.width)
                    .padding(.vertical, inset.height)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClick)
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
                // Pinching in goes back to fit. On the scroll view, not the content: on the same
                // view as the pan's drag, it holds back the drag's updates until the mouse is up.
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    if value.magnification < 0.87 { library.exitZoom() }
                })
                .onScrollGeometryChange(for: CGRect.self, of: Self.visibleArea) { _, rect in
                    scroll.origin = rect.origin
                    tracker.frame = ZoomedFrame(
                        image: CGRect(origin: CGPoint(x: inset.width - rect.minX, y: inset.height - rect.minY), size: content),
                        canvas: geometry.size
                    )
                    let visible = CGRect(
                        x: (rect.minX - inset.width) * displayScale,
                        y: (rect.minY - inset.height) * displayScale,
                        width: rect.width * displayScale,
                        height: rect.height * displayScale
                    )
                    library.setZoomViewport(visible)
                }
                .onChange(of: library.detail.map(\.id)) {
                    let detail = library.detail.filter { $0.photoID == zoom.photoID }
                    if !detail.isEmpty { tracker.detail = detail }
                }
                .onAppear {
                    guard !didScrollToFocus else { return }
                    didScrollToFocus = true
                    // Keep the clicked point under the cursor, as far as the scroll range allows.
                    let point = CGPoint(
                        x: min(max(zoom.focus.x * content.width - zoom.anchor.x * geometry.size.width, 0), max(content.width - geometry.size.width, 0)),
                        y: min(max(zoom.focus.y * content.height - zoom.anchor.y * geometry.size.height, 0), max(content.height - geometry.size.height, 0))
                    )
                    position.scrollTo(point: point)
                    onPlaced(ZoomedFrame(
                        image: CGRect(origin: CGPoint(x: inset.width - point.x, y: inset.height - point.y), size: content),
                        canvas: geometry.size
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

/// Where the image sits at 100%, in canvas coordinates (top-left origin, below the toolbar).
private struct ZoomedFrame {
    let image: CGRect
    let canvas: CGSize

    /// Where the fit view shows the image.
    var fit: CGRect { fitRect(image.size, in: canvas, padding: 28) }
}

/// The zoomed view's last layout and detail, for animating back to fit once it's gone. Not
/// view state, like `ScrollTracker`: it changes on every frame of a scroll.
private final class ZoomedTracker {
    var frame: ZoomedFrame?
    var detail: [DetailImage] = []
}

private struct ZoomTransition {
    let id = UUID()
    let base: CGImage?
    /// Full-resolution areas shown when zooming out, so the image doesn't turn soft as it starts.
    let detail: [DetailImage]
    let frame: ZoomedFrame
    let zoomingIn: Bool
}

/// Scales the image between its fit and 100% frames, covering the canvas until done. Both
/// scale and offset change linearly, so the point kept under the cursor stays there throughout.
private struct ZoomTransitionView: View {
    @Environment(\.displayScale) private var displayScale
    let transition: ZoomTransition
    let onEnd: () -> Void
    @State private var isDone = false

    var body: some View {
        let zoomed = transition.frame.image
        let atFit = isDone != transition.zoomingIn
        let frame = atFit ? transition.frame.fit : zoomed
        // An overlay, so the image's full size doesn't change the canvas layout.
        Color.clear.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let base = transition.base {
                    Image(decorative: base, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                ForEach(transition.detail) { piece in
                    Image(decorative: piece.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: piece.rect.width / displayScale, height: piece.rect.height / displayScale)
                        .offset(x: piece.rect.minX / displayScale, y: piece.rect.minY / displayScale)
                }
            }
            .frame(width: zoomed.width, height: zoomed.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(frame.width / zoomed.width, anchor: .topLeading)
            .shadow(color: .black.opacity(atFit ? 0.4 : 0), radius: 8)
            .offset(x: frame.minX, y: frame.minY)
        }
        // The zoomed view extends under the toolbar.
        .background(Color.canvas.ignoresSafeArea())
        .allowsHitTesting(false)
        .onAppear {
            // A timing curve, not a spring: the completion must come when the image has fully arrived.
            withAnimation(.easeInOut(duration: 0.25)) { isDone = true } completion: { onEnd() }
        }
    }
}

/// Scroll position read at the start of a drag. Not view state: it changes on every frame
/// of a scroll, and nothing is drawn from it.
private final class ScrollTracker {
    var origin: CGPoint = .zero
}

private enum CanvasCursor: Equatable {
    case arrow, zoomIn, openHand, closedHand, crosshair
    case resize(FrameResizePosition)
    /// Curved around the crop at this side of it.
    case rotate(FrameResizePosition)

    var style: PointerStyle {
        switch self {
        case .arrow: .default
        case .zoomIn: .zoomIn
        case .openHand: .grabIdle
        case .closedHand: .grabActive
        case .rotate(let side): .image(Image(nsImage: rotateCursorImages[side]!), hotSpot: .center)
        case .crosshair: .rectSelection
        case .resize(let position): .frameResize(position: position)
        }
    }

    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .zoomIn: .zoomIn
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .rotate(let side): Self.rotateCursors[side]!
        case .crosshair: .crosshair
        case .resize(let position): .frameResize(position: Self.appKitPosition(position), directions: .all)
        }
    }

    private static let rotateCursors = rotateCursorImages.mapValues { NSCursor(image: $0, hotSpot: NSPoint(x: 12, y: 12)) }

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

/// Curved double arrows for rotating, black on a white outline like the system cursors. There's
/// no system cursor for it. Each follows the crop's outline at its side: arched over the top,
/// bent around a corner, and so on.
private let rotateCursorImages = Dictionary(uniqueKeysWithValues: FrameResizePosition.allCases.map { side in
    let degrees: CGFloat = switch side {
    case .top: 0
    case .topLeading: 45
    case .leading: 90
    case .bottomLeading: 135
    case .bottom: 180
    case .bottomTrailing: -135
    case .trailing: -90
    case .topTrailing: -45
    }
    return (side, rotateCursorImage(turnedBy: degrees))
})

/// The rotate cursor for the top of the crop, turned counterclockwise by `degrees`.
private func rotateCursorImage(turnedBy degrees: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        let turn = NSAffineTransform()
        turn.translateX(by: 12, yBy: 12)
        turn.rotate(byDegrees: degrees)
        turn.translateX(by: -12, yBy: -12)
        turn.concat()
        let center = CGPoint(x: 12, y: 9)
        let radius: CGFloat = 8
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 25, endAngle: 155)
        // An arrowhead at each end, pointing on around the circle.
        let heads = [(degrees: 25.0, turn: -1.0), (degrees: 155.0, turn: 1.0)].map { end in
            let theta = end.degrees * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
            let along = CGVector(dx: -sin(theta) * end.turn, dy: cos(theta) * end.turn)
            let across = CGVector(dx: cos(theta), dy: sin(theta))
            let head = NSBezierPath()
            head.move(to: CGPoint(x: point.x + along.dx * 4, y: point.y + along.dy * 4))
            head.line(to: CGPoint(x: point.x + across.dx * 3.5 - along.dx, y: point.y + across.dy * 3.5 - along.dy))
            head.line(to: CGPoint(x: point.x - across.dx * 3.5 - along.dx, y: point.y - across.dy * 3.5 - along.dy))
            head.close()
            return head
        }
        NSColor.white.set()
        arc.lineWidth = 4
        arc.stroke()
        for head in heads {
            head.lineWidth = 2.5
            head.lineJoinStyle = .round
            head.stroke()
            head.fill()
        }
        NSColor.black.set()
        arc.lineWidth = 1.5
        arc.stroke()
        heads.forEach { $0.fill() }
        return true
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
    /// Outside the crop: dragging turns the photo, as in Lightroom.
    case rotate
    /// ⌘-drag: a line along something that should be level or upright, like Lightroom's angle tool.
    case level

    /// Corners and edges within a few points of the crop outline, then the inside of the crop,
    /// then anywhere outside it.
    init(at point: CGPoint, in frame: CGRect) {
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
            self = .rotate
        }
    }

    /// Which side of `frame` the pointer is on, for the rotate cursor. Inside it, during a drag
    /// that began outside, the nearest edge.
    static func side(of point: CGPoint, around frame: CGRect) -> FrameResizePosition {
        let left = point.x < frame.minX, right = point.x > frame.maxX
        if point.y < frame.minY { return left ? .topLeading : right ? .topTrailing : .top }
        if point.y > frame.maxY { return left ? .bottomLeading : right ? .bottomTrailing : .bottom }
        if left { return .leading }
        if right { return .trailing }
        let edges: [(FrameResizePosition, CGFloat)] = [
            (.top, point.y - frame.minY), (.bottom, frame.maxY - point.y),
            (.leading, point.x - frame.minX), (.trailing, frame.maxX - point.x),
        ]
        return edges.min { $0.1 < $1.1 }!.0
    }
}

/// A drag in the crop editor: what it grabbed, and the crop and angle when it began.
private struct CropDrag {
    let target: CropTarget
    let crop: CropRect
    let straighten: Double
    /// Direction of the pointer from the photo's center when the drag began, in degrees.
    let pointerAngle: Double
}

struct CropEditorView: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo
    let image: CGImage?

    @State private var drag: CropDrag?
    @State private var hover: CropTarget?
    /// Where the pointer is around the crop, which the rotate cursor follows, also during a drag.
    @State private var rotateSide: FrameResizePosition = .top
    /// Holding ⌘ turns a drag into drawing a level line.
    @State private var isCommandDown = false
    @State private var levelLine: (start: CGPoint, end: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            if let imageSize = photo.geometrySize {
                editor(viewSize: geometry.size, imageSize: imageSize)
            }
        }
        .onModifierKeysChanged(mask: .command) { _, keys in isCommandDown = keys.contains(.command) }
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

            // Thirds while framing; a finer grid while straightening, to line up with.
            let isStraightening = library.isStraightening
            gridPath(in: cropFrame, fine: isStraightening)
                .stroke(Color.white.opacity(drag != nil || isStraightening ? 0.5 : 0.25), lineWidth: 0.5)
                .allowsHitTesting(false)

            Rectangle()
                .path(in: cropFrame)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .allowsHitTesting(false)

            handlesPath(around: cropFrame)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .allowsHitTesting(false)

            if let levelLine {
                Path { path in
                    path.move(to: levelLine.start)
                    path.addLine(to: levelLine.end)
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .shadow(color: .black.opacity(0.6), radius: 1)
                .allowsHitTesting(false)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                hover = CropTarget(at: point, in: cropFrame)
                rotateSide = CropTarget.side(of: point, around: cropFrame)
            } else {
                hover = nil
            }
        }
        .gesture(dragGesture(cropFrame: cropFrame, box: box, imageSize: imageSize))
        // Double-clicking inside the crop finishes it, as in Lightroom.
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            if cropFrame.contains(value.location) { library.endCrop() }
        })
        .cursor(cursor)
    }

    /// A drag keeps the cursor of what it grabbed, even when the pointer moves off it.
    private var cursor: CanvasCursor {
        if drag == nil, isCommandDown, hover != nil { return .crosshair }
        switch drag?.target ?? hover {
        case .move: return drag == nil ? .openHand : .closedHand
        case .resize(let handle): return .resize(handle.resizePosition)
        case .rotate: return .rotate(rotateSide)
        case .level: return .crosshair
        case nil: return .arrow
        }
    }

    /// Corner brackets and edge bars just outside the crop, so they don't cover the photo.
    private func handlesPath(around frame: CGRect) -> Path {
        let thickness: CGFloat = 3
        let length = min(18, frame.width / 2, frame.height / 2) + thickness
        let bar: CGFloat = 18
        return Path { path in
            for handle in CropHandle.allCases {
                let point = handle.point(in: frame)
                // Outward direction of the handle's sides; 0 along an edge.
                let dx: CGFloat = handle.movesLeft ? -1 : handle.movesRight ? 1 : 0
                let dy: CGFloat = handle.movesTop ? -1 : handle.movesBottom ? 1 : 0
                if handle.isCorner {
                    let x = dx < 0 ? point.x - thickness : point.x + thickness - length
                    let y = dy < 0 ? point.y - thickness : point.y + thickness - length
                    path.addRect(CGRect(x: x, y: dy < 0 ? point.y - thickness : point.y, width: length, height: thickness))
                    path.addRect(CGRect(x: dx < 0 ? point.x - thickness : point.x, y: y, width: thickness, height: length))
                } else if dx == 0 {
                    path.addRect(CGRect(x: point.x - bar / 2, y: dy < 0 ? point.y - thickness : point.y, width: bar, height: thickness))
                } else {
                    path.addRect(CGRect(x: dx < 0 ? point.x - thickness : point.x, y: point.y - bar / 2, width: thickness, height: bar))
                }
            }
        }
    }

    /// Rule-of-thirds lines, or a grid of roughly square cells when `fine`.
    private func gridPath(in rect: CGRect, fine: Bool) -> Path {
        let cell = max(min(rect.width, rect.height) / 6, 1)
        let columns = fine ? max(Int((rect.width / cell).rounded()), 2) : 3
        let rows = fine ? max(Int((rect.height / cell).rounded()), 2) : 3
        return Path { path in
            for i in 1..<columns {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for i in 1..<rows {
                let y = rect.minY + rect.height * CGFloat(i) / CGFloat(rows)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }

    private func dragGesture(cropFrame: CGRect, box: CGRect, imageSize: CGSize) -> some Gesture {
        let center = CGPoint(x: box.midX, y: box.midY)
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let settings = photo.settings
                // The event's own modifiers, not the keyboard's state when the handler runs.
                let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                if drag == nil {
                    let target = modifiers.contains(.command) ? .level : CropTarget(at: value.startLocation, in: cropFrame)
                    drag = CropDrag(
                        target: target,
                        crop: settings.crop,
                        straighten: settings.straighten,
                        pointerAngle: angle(of: value.startLocation, around: center)
                    )
                    // Shows the finer grid, and keeps the crop the angle started from.
                    if target == .rotate || target == .level { library.beginStraighten() }
                }
                guard let drag else { return }
                switch drag.target {
                case .rotate:
                    rotateSide = CropTarget.side(of: value.location, around: cropFrame)
                    // The photo turns with the pointer around its center.
                    let turn = remainder(angle(of: value.location, around: center) - drag.pointerAngle, 360)
                    library.setStraighten(drag.straighten + turn)
                case .level:
                    levelLine = (value.startLocation, value.location)
                case .move, .resize:
                    let dx = value.translation.width / box.width
                    let dy = value.translation.height / box.height
                    // A fixed ratio in normalized units; Shift keeps a free crop's proportions.
                    let fixed = CropGeometry.pixelAspect(for: settings.aspectRatio, matching: drag.crop, imageSize: imageSize)
                        .map { $0 / Double(imageSize.width / imageSize.height) }
                    let aspect = fixed ?? (modifiers.contains(.shift) ? drag.crop.width / drag.crop.height : nil)
                    let proposal = proposedRect(
                        from: drag.crop, target: drag.target, dx: dx, dy: dy,
                        aspect: aspect, fromCenter: modifiers.contains(.option)
                    )
                    let rect = CropGeometry.constrained(from: settings.crop, to: proposal, angle: settings.straighten, imageSize: imageSize)
                    library.setCrop(rect)
                }
            }
            .onEnded { value in
                if let levelLine { level(along: levelLine) }
                if drag?.target == .rotate || drag?.target == .level { library.endStraighten() }
                levelLine = nil
                drag = nil
                hover = CropTarget(at: value.location, in: cropFrame)
            }
    }

    /// Direction from `center` to `point` in degrees, clockwise from the right (y points down).
    private func angle(of point: CGPoint, around center: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    /// Turns the photo so that a line drawn along a horizon becomes level, or one drawn along
    /// something upright becomes vertical.
    private func level(along line: (start: CGPoint, end: CGPoint)) {
        let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
        guard hypot(dx, dy) > 12 else { return }  // A click, not a line.
        var tilt = atan2(dy, dx) * 180 / .pi
        // The direction it was drawn in doesn't matter.
        if tilt > 90 { tilt -= 180 } else if tilt <= -90 { tilt += 180 }
        if abs(tilt) > 45 { tilt -= tilt > 0 ? 90 : -90 }
        library.setStraighten(photo.settings.straighten - tilt)
    }

    /// The crop after dragging `target` by `dx`, `dy` (normalized). With `aspect`, it keeps that
    /// width-to-height ratio in normalized units; with `fromCenter`, the opposite side moves too.
    private func proposedRect(from start: CropRect, target: CropTarget, dx: Double, dy: Double, aspect: Double?, fromCenter: Bool) -> CropRect {
        guard case .resize(let handle) = target else {
            let x = min(max(start.x + dx, 0), 1 - start.width)
            let y = min(max(start.y + dy, 0), 1 - start.height)
            return CropRect(x: x, y: y, width: start.width, height: start.height)
        }

        let minSize = CropGeometry.minimumSize
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if fromCenter {
            var halfWidth = start.width / 2, halfHeight = start.height / 2
            if handle.movesLeft { halfWidth -= dx } else if handle.movesRight { halfWidth += dx }
            if handle.movesTop { halfHeight -= dy } else if handle.movesBottom { halfHeight += dy }
            halfWidth = min(max(halfWidth, minSize / 2), min(start.midX, 1 - start.midX))
            halfHeight = min(max(halfHeight, minSize / 2), min(start.midY, 1 - start.midY))
            minX = start.midX - halfWidth
            maxX = start.midX + halfWidth
            minY = start.midY - halfHeight
            maxY = start.midY + halfHeight
        } else {
            if handle.movesLeft { minX = min(max(start.minX + dx, 0), maxX - minSize) }
            if handle.movesRight { maxX = max(min(start.maxX + dx, 1), minX + minSize) }
            if handle.movesTop { minY = min(max(start.minY + dy, 0), maxY - minSize) }
            if handle.movesBottom { maxY = max(min(start.maxY + dy, 1), minY + minSize) }
        }

        guard let aspect else { return CropRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY) }
        var width = maxX - minX
        var height = maxY - minY
        // An edge sets the other axis to match; a corner grows the shorter side.
        if handle == .left || handle == .right {
            height = width / aspect
        } else if handle == .top || handle == .bottom {
            width = height * aspect
        } else if width / height > aspect {
            height = width / aspect
        } else {
            width = height * aspect
        }
        // The axis an edge doesn't move stays centered; a corner stays anchored at the opposite
        // corner, or at the center.
        func center(movesLow: Bool, movesHigh: Bool, low: Double, high: Double, size: Double, middle: Double) -> Double {
            if fromCenter || !(movesLow || movesHigh) { return middle }
            return movesLow ? high - size / 2 : low + size / 2
        }
        return CropRect(
            centerX: center(movesLow: handle.movesLeft, movesHigh: handle.movesRight, low: minX, high: maxX, size: width, middle: start.midX),
            centerY: center(movesLow: handle.movesTop, movesHigh: handle.movesBottom, low: minY, high: maxY, size: height, middle: start.midY),
            width: width,
            height: height
        )
    }
}
