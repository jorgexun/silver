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
    @Environment(\.displayScale) private var displayScale
    let photo: Photo

    /// Scroll position where a pan of the zoomed view started; nil when not panning.
    @State private var panStart: CGPoint?
    @State private var zoomed = ZoomedTracker()
    /// Set when zooming in from the fit view, until the zoomed view knows where the image goes.
    @State private var animatesZoomIn = false
    @State private var transition: ZoomTransition?
    /// Where a pinch or the zoom slider left the image, kept up until the view at the new zoom
    /// is in place. During the change, the image's place comes from `library.liveZoom`.
    @State private var heldFrame: LiveFrame?
    @State private var heldFrameEnd: Task<Void, Never>?
    /// The zoom a pinch started from, with the point between the fingers; nil when not pinching.
    @State private var pinch: ZoomState?
    /// Resets when a pinch ends or is cancelled.
    @GestureState private var isPinching = false
    /// The zoom, shown for a moment after it changes.
    @State private var zoomLabel: String?
    @State private var zoomLabelEnd: Task<Void, Never>?
    /// A single click waiting to see whether it becomes a double-click.
    @State private var pendingClick: Task<Void, Never>?

    private struct ZoomKey: Hashable {
        let photoID: Photo.ID?
        let scale: CGFloat?
    }

    var body: some View {
        let preview = library.preview?.photoID == photo.id ? library.preview : nil
        let placeholder = library.placeholder?.photoID == photo.id ? library.placeholder : nil
        // Right after cropping, until the cropped preview has rendered, the crop editor's preview
        // is cropped here, so the whole photo doesn't flash up.
        let uncropped = preview?.hasGeometry == false ? preview?.image : nil
        let image = (uncropped == nil ? preview?.image : nil) ?? placeholder?.image ?? photo.thumbnail
        let isZoomed = library.zoom?.photoID == photo.id
        let canvas = library.canvasSize ?? .zero
        let live = library.liveZoom.flatMap { $0.photoID == photo.id ? $0 : nil }
        let floating = live.flatMap { liveFrame(for: $0, canvas: canvas) } ?? heldFrame
        Group {
            if let zoom = library.zoom, isZoomed {
                ZoomedCanvas(
                    zoom: zoom, fullSize: photo.fullSize, base: image, dragStart: $panStart, tracker: zoomed,
                    onClick: { click { library.exitZoom() } },
                    onPinch: pinchChanged, onPinchEnd: pinchEnded,
                    onPlaced: { from, to in placed(from: from, to: to, base: image) },
                    onSettled: settled
                )
                .id(zoom.photoID)  // Fresh scroll state for each photo.
            } else {
                fitCanvas(image: image, uncropped: uncropped)
            }
        }
        .overlay {
            if let floating {
                FloatingImage(
                    base: image, detail: library.detail.filter { $0.photoID == photo.id },
                    frame: floating.rect, layoutSize: floating.rect.size, isFit: floating.isFit
                )
            } else if let transition {
                ZoomTransitionView(transition: transition) {
                    if self.transition?.id == transition.id { self.transition = nil }
                }
                .id(transition.id)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { library.setCanvas($0, scale: displayScale) }
        .onChange(of: displayScale) {
            if let size = library.canvasSize { library.setCanvas(size, scale: displayScale) }
        }
        .onChange(of: isZoomed) { _, isZoomed in
            transition = nil
            let animates = !reduceMotion && library.zoomAnimates
            if isZoomed {
                animatesZoomIn = animates
            } else if animates, let frame = zoomed.frame {
                let detail = zoomed.detail.filter { $0.photoID == photo.id }
                transition = ZoomTransition(base: image, detail: detail, from: frame.image, to: frame.fit, toFit: true)
            }
            // The transition keeps what it shows; up to 160 MB of tiles needn't wait for the next zoom.
            zoomed.detail = []
        }
        .onChange(of: library.liveZoom) { old, new in liveZoomChanged(from: old, to: new, canvas: canvas) }
        .onChange(of: isPinching) { _, pinching in
            if !pinching { pinchEnded() }
        }
        .onChange(of: shownScale) { _, scale in showZoomLabel(scale) }
        .onDisappear {
            pendingClick?.cancel()
            heldFrameEnd?.cancel()
            zoomLabelEnd?.cancel()
        }
        // On the container, so the cursor follows a click that zooms in or out. A new zoomed view
        // under the pointer takes the cursor, so it's held when the zoom changes.
        .cursor(
            cursor(isZoomed: isZoomed, hasImage: image != nil),
            area: cursorArea(isZoomed: isZoomed, fit: fitFrame(image: image, uncropped: uncropped, in: canvas)),
            holdKey: ZoomKey(photoID: library.zoom?.photoID, scale: library.zoom?.scale)
        )
        .contextMenu { PhotoContextMenu(photo: photo) }
        .overlay(alignment: .top) {
            if library.showOriginal {
                Text("Original")
                    .canvasLabel()
                    .padding(.top, 12)
            }
        }
        .overlay(alignment: .bottom) {
            if let zoomLabel {
                Text(zoomLabel)
                    .monospacedDigit()
                    .canvasLabel()
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
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

    /// The photo's cursor, shown over `cursorArea`. A pan keeps its cursor anywhere.
    private func cursor(isZoomed: Bool, hasImage: Bool) -> CanvasCursor {
        if panStart != nil { return .closedHand }
        if isZoomed { return .openHand }
        return hasImage ? .zoomIn : .arrow
    }

    /// Where the photo is, which is where its cursor shows and its clicks act. Read as the
    /// pointer moves, so the zoomed photo's place comes from the tracker as it scrolls.
    private func cursorArea(isZoomed: Bool, fit: CGRect?) -> (() -> CGRect?)? {
        if panStart != nil { return nil }
        if isZoomed { return { [zoomed] in zoomed.frame?.image } }
        return { fit }
    }

    /// Where the fit view shows the photo in a canvas of `size`.
    private func fitFrame(image: CGImage?, uncropped: CGImage?, in size: CGSize) -> CGRect? {
        let crop = photo.settings.crop
        if let uncropped {
            let cropped = CGSize(width: crop.width * Double(uncropped.width), height: crop.height * Double(uncropped.height))
            return LibraryModel.fitRect(cropped, in: size)
        }
        return image.map { LibraryModel.fitRect(CGSize(width: $0.width, height: $0.height), in: size) }
    }

    private func fitCanvas(image: CGImage?, uncropped: CGImage?) -> some View {
        GeometryReader { geometry in
            let frame = fitFrame(image: image, uncropped: uncropped, in: geometry.size)
            ZStack {
                if let uncropped, let frame {
                    croppedImage(uncropped, in: frame)
                } else if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .padding(LibraryModel.fitPadding)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard let frame, frame.contains(location) else { return }
                // Keeps the clicked point under the pointer.
                let (focus, anchor) = Self.focusAndAnchor(at: location, in: frame, canvas: geometry.size)
                click { library.toggleZoom(focus: focus, anchor: anchor) }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($isPinching) { _, pinching, _ in pinching = true }
                    .onChanged { value in pinchChanged(value.magnification, at: value.startLocation) }
            )
        }
    }

    /// A preview without crop and straighten, turned and cropped the way the crop editor shows it,
    /// filling `frame`.
    private func croppedImage(_ image: CGImage, in frame: CGRect) -> some View {
        let settings = photo.settings
        let crop = settings.crop
        let size = CGSize(width: frame.width / crop.width, height: frame.height / crop.height)
        return Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(settings.straighten))
            .offset(x: (0.5 - crop.midX) * size.width, y: (0.5 - crop.midY) * size.height)
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .shadow(color: .black.opacity(0.4), radius: 8)
            .position(x: frame.midX, y: frame.midY)
    }

    /// The image point at `location`, normalized to the image's `frame`, and where `location` is,
    /// normalized to the canvas: a zoom's focus and anchor that keep the point under the pointer.
    private static func focusAndAnchor(at location: CGPoint, in frame: CGRect, canvas: CGSize) -> (CGPoint, CGPoint) {
        let focus = CGPoint(
            x: min(max((location.x - frame.minX) / max(frame.width, 1), 0), 1),
            y: min(max((location.y - frame.minY) / max(frame.height, 1), 0), 1)
        )
        return (focus, CGPoint(x: location.x / max(canvas.width, 1), y: location.y / max(canvas.height, 1)))
    }

    // MARK: Pinch and live zoom

    /// Zooms as the fingers spread or close, keeping the image point between them where it
    /// was. `location` is where the pinch started, in the canvas.
    private func pinchChanged(_ magnification: CGFloat, at location: CGPoint) {
        if pinch == nil {
            guard let fit = library.fitScale, let fullSize = photo.fullSize, let canvas = library.canvasSize else { return }
            let zoom = library.zoom?.photoID == photo.id ? library.zoom : nil
            guard let frame = zoom == nil ? LibraryModel.fitRect(fullSize, in: canvas) : zoomed.frame?.image else { return }
            let (focus, anchor) = Self.focusAndAnchor(at: location, in: frame, canvas: canvas)
            pinch = ZoomState(photoID: photo.id, scale: zoom?.scale ?? fit, focus: focus, anchor: anchor)
        }
        guard let pinch else { return }
        library.updateLiveZoom(scale: pinch.scale * magnification, focus: pinch.focus, anchor: pinch.anchor)
    }

    private func pinchEnded() {
        guard pinch != nil else { return }
        pinch = nil
        library.endLiveZoom()
    }

    /// Where `live` puts the image in the canvas.
    private func liveFrame(for live: ZoomState, canvas: CGSize) -> LiveFrame? {
        guard let fullSize = photo.fullSize, canvas.width > 0 else { return nil }
        let content = ZoomedFrame.contentSize(fullSize, scale: live.scale, displayScale: displayScale)
        let frame = ZoomedFrame(zoom: live, content: content, canvas: canvas)
        return LiveFrame(rect: frame.image, isFit: library.isFit(live.scale))
    }

    private func liveZoomChanged(from old: ZoomState?, to new: ZoomState?, canvas: CGSize) {
        heldFrameEnd?.cancel()
        if let new, new.photoID == photo.id {
            if old == nil {
                transition = nil
                heldFrame = nil
            }
            return
        }
        // Over. Until the zoomed view is in place at the new zoom (see `settled()`), the image
        // stays where it was. The fit view needs no placing.
        guard let old, old.photoID == photo.id, library.zoom?.photoID == photo.id, let frame = liveFrame(for: old, canvas: canvas) else {
            heldFrame = nil
            return
        }
        heldFrame = frame
        heldFrameEnd = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            heldFrame = nil
        }
    }

    /// The zoomed view knows where the image goes, before showing it there.
    private func placed(from: ZoomedFrame?, to: ZoomedFrame, base: CGImage?) {
        if animatesZoomIn {
            animatesZoomIn = false
            transition = ZoomTransition(base: base, detail: [], from: to.fit, to: to.image, fromFit: true)
        } else if let from, from.image != to.image, library.zoomAnimates, !reduceMotion {
            // A step of ⌘+ or ⌘−.
            let detail = zoomed.detail.filter { $0.photoID == photo.id }
            transition = ZoomTransition(base: base, detail: detail, from: from.image, to: to.image)
        }
    }

    /// The zoomed view shows the image where it was placed.
    private func settled() {
        guard library.liveZoom == nil, heldFrame != nil else { return }
        heldFrameEnd?.cancel()
        heldFrame = nil
    }

    /// The zoom shown, live or settled; nil when the photo fits.
    private var shownScale: CGFloat? {
        if let live = library.liveZoom, live.photoID == photo.id { return live.scale }
        return library.zoom?.photoID == photo.id ? library.zoom?.scale : nil
    }

    private func showZoomLabel(_ scale: CGFloat?) {
        let text = scale.map { library.isFit($0) ? "Fit" : "\(Int(($0 * 100).rounded()))%" } ?? "Fit"
        guard text != zoomLabel else { return }
        zoomLabel = text
        zoomLabelEnd?.cancel()
        zoomLabelEnd = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { zoomLabel = nil }
        }
    }
}

/// The photo zoomed in: a scroll view the size of the image at the zoom. The fit preview,
/// enlarged, fills in until the visible area has been rendered at that scale on top of it.
private struct ZoomedCanvas: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.displayScale) private var displayScale
    let zoom: ZoomState
    /// The photo's full-resolution output size, once known.
    let fullSize: CGSize?
    let base: CGImage?
    @Binding var dragStart: CGPoint?
    let tracker: ZoomedTracker
    let onClick: () -> Void
    /// A pinch's magnification and where it started, in the canvas.
    let onPinch: (CGFloat, CGPoint) -> Void
    let onPinchEnd: () -> Void
    /// Called once the image's place at the zoom is known, before it is shown there: when the
    /// view appears, and when the zoom changes, with where the image was before.
    let onPlaced: (ZoomedFrame?, ZoomedFrame) -> Void
    /// Called once the scroll view shows the image where it was placed.
    let onSettled: () -> Void

    @State private var position = ScrollPosition()
    @State private var scroll = ScrollTracker()
    @State private var didScrollToFocus = false
    /// The scroll position and content size being moved to, until the scroll view has them.
    @State private var placing: ScrollArea?
    /// The scroll view's origin in the canvas, which it may extend beyond, for placing a pinch.
    @State private var origin: CGPoint = .zero
    @GestureState private var isPinching = false

    private static let canvasSpace = "ZoomedCanvas"

    var body: some View {
        GeometryReader { geometry in
            if let fullSize {
                let content = ZoomedFrame.contentSize(fullSize, scale: zoom.scale, displayScale: displayScale)
                let inset = ZoomedFrame.inset(content: content, canvas: geometry.size)
                ScrollView([.horizontal, .vertical]) {
                    // Pieces rendered at the zoom are drawn pixel for pixel, up to 100%.
                    ZoomedImage(
                        base: base,
                        detail: library.detail.filter { $0.photoID == zoom.photoID },
                        size: content,
                        pixelScale: zoom.scale <= 1 ? displayScale : nil
                    )
                    // On the photo, not the space around a photo smaller than the canvas.
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
                    .padding(.horizontal, inset.width)
                    .padding(.vertical, inset.height)
                }
                .scrollIndicators(.automatic)
                .scrollPosition($position)
                // On the scroll view, not the content: on the same view as the pan's drag, it
                // holds back the drag's updates until the mouse is up.
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($isPinching) { _, pinching, _ in pinching = true }
                        .onChanged { value in
                            onPinch(value.magnification, CGPoint(x: value.startLocation.x + origin.x, y: value.startLocation.y + origin.y))
                        }
                )
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named(Self.canvasSpace)).origin } action: { origin = $0 }
                .onScrollGeometryChange(for: ScrollArea.self, of: Self.scrollArea) { _, area in
                    let rect = area.visible
                    scroll.origin = rect.origin
                    tracker.frame = ZoomedFrame(
                        image: CGRect(origin: CGPoint(x: inset.width - rect.minX, y: inset.height - rect.minY), size: content),
                        canvas: geometry.size
                    )
                    // In full-resolution pixels.
                    let pixels = displayScale / zoom.scale
                    let visible = CGRect(
                        x: (rect.minX - inset.width) * pixels,
                        y: (rect.minY - inset.height) * pixels,
                        width: rect.width * pixels,
                        height: rect.height * pixels
                    )
                    library.setZoomViewport(visible, scale: zoom.scale)
                    if let placing, area.isClose(to: placing) {
                        self.placing = nil
                        onSettled()
                    }
                }
                .onChange(of: library.detail.map(\.id)) {
                    let detail = library.detail.filter { $0.photoID == zoom.photoID }
                    if !detail.isEmpty { tracker.detail = detail }
                }
                .onAppear {
                    guard !didScrollToFocus else { return }
                    didScrollToFocus = true
                    place(content: content, inset: inset, canvas: geometry.size, from: nil)
                }
                .onChange(of: zoom) {
                    place(content: content, inset: inset, canvas: geometry.size, from: tracker.frame)
                }
            } else {
                ZStack {
                    if let base {
                        Image(decorative: base, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(LibraryModel.fitPadding)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .coordinateSpace(.named(Self.canvasSpace))
        // Resets both when a pinch ends and when it's cancelled.
        .onChange(of: isPinching) { _, pinching in
            if !pinching { onPinchEnd() }
        }
    }

    /// Scrolls so the zoom's focus is under its anchor, as far as the scroll range allows.
    private func place(content: CGSize, inset: CGSize, canvas: CGSize, from: ZoomedFrame?) {
        let point = ZoomedFrame.scrollPoint(zoom: zoom, content: content, canvas: canvas)
        position.scrollTo(point: point)
        placing = ScrollArea(
            visible: CGRect(origin: point, size: canvas),
            contentSize: CGSize(width: content.width + inset.width * 2, height: content.height + inset.height * 2)
        )
        onPlaced(from, ZoomedFrame(zoom: zoom, content: content, canvas: canvas))
    }

    /// The area not covered by the sidebar, inspector or toolbar, in content coordinates, and the
    /// content size. The area's origin is the point `scrollTo(point:)` takes; `visibleRect` also
    /// covers the insets.
    private nonisolated static func scrollArea(_ geometry: ScrollGeometry) -> ScrollArea {
        ScrollArea(
            visible: CGRect(
                x: geometry.contentOffset.x + geometry.contentInsets.leading,
                y: geometry.contentOffset.y + geometry.contentInsets.top,
                width: geometry.containerSize.width,
                height: geometry.containerSize.height
            ),
            contentSize: geometry.contentSize
        )
    }
}

private nonisolated struct ScrollArea: Equatable {
    let visible: CGRect
    let contentSize: CGSize

    /// Whether this is `other`'s position and content size, to within half a point.
    func isClose(to other: ScrollArea) -> Bool {
        abs(visible.minX - other.visible.minX) < 0.5 && abs(visible.minY - other.visible.minY) < 0.5
            && abs(contentSize.width - other.contentSize.width) < 0.5 && abs(contentSize.height - other.contentSize.height) < 0.5
    }
}

/// The photo drawn at `size`: the fit preview, enlarged, with the rendered pieces on top.
private struct ZoomedImage: View {
    let base: CGImage?
    let detail: [DetailImage]
    let size: CGSize
    /// Screen pixels per point, to draw pieces rendered at this size pixel for pixel. Without
    /// it, or for pieces rendered at another scale, they are scaled to fit the image.
    var pixelScale: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let base {
                Image(decorative: base, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
            ForEach(detail) { piece in
                if let pixelScale, abs(piece.size.width / pixelScale - size.width) < 1 {
                    Image(decorative: piece.image, scale: pixelScale)
                        .interpolation(.none)
                        .offset(x: piece.rect.minX / pixelScale, y: piece.rect.minY / pixelScale)
                } else {
                    let frame = piece.frame(in: size)
                    Image(decorative: piece.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

/// Where the image sits when zoomed, in canvas coordinates (top-left origin, below the toolbar).
private struct ZoomedFrame: Equatable {
    let image: CGRect
    let canvas: CGSize

    /// Where the fit view shows the image.
    var fit: CGRect { LibraryModel.fitRect(image.size, in: canvas) }

    /// Where `zoom` puts an image of `content` size: its focus under its anchor, as far as the
    /// scroll range allows, and centered where it's smaller than the canvas.
    init(zoom: ZoomState, content: CGSize, canvas: CGSize) {
        let inset = Self.inset(content: content, canvas: canvas)
        let point = Self.scrollPoint(zoom: zoom, content: content, canvas: canvas)
        self.init(image: CGRect(origin: CGPoint(x: inset.width - point.x, y: inset.height - point.y), size: content), canvas: canvas)
    }

    /// Space around an image smaller than the canvas, which centers it.
    static func inset(content: CGSize, canvas: CGSize) -> CGSize {
        CGSize(width: max((canvas.width - content.width) / 2, 0), height: max((canvas.height - content.height) / 2, 0))
    }

    /// The scroll position that puts `zoom`'s focus under its anchor, as far as the scroll range allows.
    static func scrollPoint(zoom: ZoomState, content: CGSize, canvas: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(zoom.focus.x * content.width - zoom.anchor.x * canvas.width, 0), max(content.width - canvas.width, 0)),
            y: min(max(zoom.focus.y * content.height - zoom.anchor.y * canvas.height, 0), max(content.height - canvas.height, 0))
        )
    }

    init(image: CGRect, canvas: CGSize) {
        self.image = image
        self.canvas = canvas
    }

    /// Size in points of an image `fullSize` pixels at full resolution, at `scale`.
    static func contentSize(_ fullSize: CGSize, scale: CGFloat, displayScale: CGFloat) -> CGSize {
        CGSize(width: fullSize.width * scale / displayScale, height: fullSize.height * scale / displayScale)
    }
}

/// The zoomed view's last layout and detail, for animating back to fit once it's gone. Not
/// view state, like `ScrollTracker`: it changes on every frame of a scroll.
private final class ZoomedTracker {
    var frame: ZoomedFrame?
    var detail: [DetailImage] = []
}

/// Where a pinch or the zoom slider has the image, in canvas coordinates.
private struct LiveFrame: Equatable {
    let rect: CGRect
    /// At the fit zoom, where the fit view's shadow shows.
    let isFit: Bool
}

/// The photo at `frame` over the canvas, covering it: during a pinch or a drag of the zoom
/// slider, where scaling what's already rendered keeps up with the fingers, and in zoom
/// transitions.
private struct FloatingImage: View {
    let base: CGImage?
    let detail: [DetailImage]
    let frame: CGRect
    /// Laid out at this size and scaled to `frame`, so a transition animates only the scale.
    let layoutSize: CGSize
    /// At the fit zoom, where the fit view's shadow shows.
    let isFit: Bool

    var body: some View {
        // An overlay, so the image's size doesn't change the canvas layout.
        Color.clear.overlay(alignment: .topLeading) {
            ZoomedImage(base: base, detail: detail, size: layoutSize)
                .scaleEffect(frame.width / layoutSize.width, anchor: .topLeading)
                .shadow(color: .black.opacity(isFit ? 0.4 : 0), radius: 8)
                .offset(x: frame.minX, y: frame.minY)
        }
        // The zoomed view extends under the toolbar.
        .background(Color.canvas.ignoresSafeArea())
        .allowsHitTesting(false)
    }
}

private struct ZoomTransition {
    let id = UUID()
    let base: CGImage?
    /// Rendered areas, so the image doesn't turn soft as it starts.
    let detail: [DetailImage]
    let from: CGRect
    let to: CGRect
    /// Whether the image starts or ends in the fit view, which has a shadow.
    var fromFit = false
    var toFit = false
}

/// Scales the image from one frame to another, e.g. between fit and 100%, covering the canvas
/// until done. Both scale and offset change linearly, so the point kept under the cursor stays
/// there throughout.
private struct ZoomTransitionView: View {
    let transition: ZoomTransition
    let onEnd: () -> Void
    @State private var isDone = false

    var body: some View {
        FloatingImage(
            base: transition.base,
            detail: transition.detail,
            frame: isDone ? transition.to : transition.from,
            layoutSize: transition.to.width > transition.from.width ? transition.to.size : transition.from.size,
            isFit: isDone ? transition.toFit : transition.fromFit
        )
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

    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .zoomIn: .zoomIn
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .rotate(let side): rotateCursors[side]!
        case .crosshair: .crosshair
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

/// Curved double arrows for rotating, black on a white outline like the system cursors. There's
/// no system cursor for it. Each follows the crop's outline at its side: arched over the top,
/// bent around a corner, and so on.
private let rotateCursors = Dictionary(uniqueKeysWithValues: FrameResizePosition.allCases.map { side in
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
    return (side, NSCursor(image: rotateCursorImage(turnedBy: degrees), hotSpot: NSPoint(x: 12, y: 12)))
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
    /// Shows `cursor` over this view, also while it changes under a still pointer and during a
    /// drag, and the arrow once the pointer leaves or the view goes away (see CLAUDE.md).
    /// - Parameters:
    ///   - area: Where in the view the cursor shows, read as the pointer moves; elsewhere it's
    ///     the arrow. Nil, or returning nil, for the whole view.
    ///   - holdKey: Changes when views may have appeared under the pointer and taken the cursor.
    fileprivate func cursor(_ cursor: CanvasCursor, area: (() -> CGRect?)? = nil, holdKey: AnyHashable? = nil) -> some View {
        overlay(CursorArea(cursor: cursor.nsCursor, area: area, holdKey: holdKey).allowsHitTesting(false))
    }
}

/// An AppKit view that owns the cursor over its frame. SwiftUI's `pointerStyle` kept showing
/// the loupe's cursor over the grid after leaving the loupe.
private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor
    let area: (() -> CGRect?)?
    let holdKey: AnyHashable?

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.area = area
        view.update(cursor: cursor, holdKey: holdKey)
    }
}

private final class CursorView: NSView {
    var area: (() -> CGRect?)?
    private var cursor: NSCursor = .arrow
    private var holdKey: AnyHashable?
    /// Until when the cursor is set on every frame; see `holdCursor()`.
    private var holdDeadline: TimeInterval = 0
    private var holdTimer: Timer?
    /// Clicks get the arrow the same way, so they start a hold too.
    private var clicks: Any?

    // Top-left origin, like SwiftUI.
    override var isFlipped: Bool { true }

    // Clicks, scrolls and gestures go to the views below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(cursor: NSCursor, holdKey: AnyHashable?) {
        let changed = cursor != self.cursor || holdKey != self.holdKey
        self.cursor = cursor
        self.holdKey = holdKey
        // The area may have moved under a still pointer too.
        showCursor()
        if changed { holdCursor() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { showCursor() }

    // Set on every move, so nothing else's cursor lingers.
    override func mouseMoved(with event: NSEvent) { showCursor() }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// The cursor for where the pointer is: this view's in its area, the arrow elsewhere in the
    /// view. Nil when the pointer isn't over the view.
    private var cursorAtPointer: NSCursor? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return nil }
        return area?().map { $0.contains(point) } ?? true ? cursor : .arrow
    }

    private func showCursor() {
        if NSApp.isActive, let cursor = cursorAtPointer { cursor.set() }
    }

    /// Keeps this view's cursor for a moment. A view appearing under a still pointer, e.g. the
    /// zoomed scroll view, gets a cursor update that SwiftUI's hosting view answers with the
    /// arrow, after this view has set its cursor; so do clicks. Those updates don't go through
    /// the event queue and don't reach this view, so the cursor is set on every frame until
    /// things settle. `NSCursor.current` doesn't always tell when it was changed.
    private func holdCursor() {
        guard window != nil, cursorAtPointer != nil else { return }
        holdDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        guard holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, ProcessInfo.processInfo.systemUptime < self.holdDeadline else {
                    timer.invalidate()
                    self?.holdTimer = nil
                    return
                }
                self.showCursor()
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        // Gone from under the pointer, e.g. back to the grid, which sets no cursor of its own.
        if cursorAtPointer != nil { NSCursor.arrow.set() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if clicks == nil {
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
                if let self, event.window === self.window { self.holdCursor() }
                return event
            }
        }
        // Appeared under a still pointer, e.g. the crop editor replacing the photo: after the
        // view it replaces has gone, which resets the cursor.
        DispatchQueue.main.async { [weak self] in self?.showCursor() }
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
        let box = LibraryModel.fitRect(imageSize, in: viewSize, padding: 36)
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
                    Color.imagePlaceholder
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
