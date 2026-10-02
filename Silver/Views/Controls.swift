import SwiftUI

extension Color {
    /// Neutral background behind photos.
    static let canvas = Color(white: 0.11)
    /// Outline of selected thumbnails. Lighter than the accent color (a mid gray, so the white
    /// text on sidebar highlights and buttons stays readable).
    static let selectionRing = Color(white: 0.68)
}

/// How a `TrackSlider` draws its track.
enum TrackStyle {
    /// A neutral track.
    case plain
    /// A color scale, e.g. blue to yellow for temperature. It has no fill, which would hide the
    /// scale; the knob's place on it shows the value.
    case gradient([Color])
    /// A neutral track with a tick every `tick` units, e.g. degrees.
    case ruler(tick: Double)
}

/// A slider drawn as a thin track. The fill runs from `origin` (the default value) to the value,
/// so an untouched adjustment shows no fill, and a mark shows where the origin is.
///
/// Dragging the knob moves it from where it is; pressing elsewhere on the track jumps there
/// first. Holding Option while dragging moves it ten times slower. Double-clicking resets it.
struct TrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Where the fill starts.
    let origin: Double
    var style: TrackStyle = .plain
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Called on a double-click, as in Lightroom and Photos.
    var onReset: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @State private var drag: Drag?
    /// Resets when the drag ends or is cancelled; `onEnded` only runs for the former.
    @GestureState private var isDragging = false

    private struct Drag {
        var lastX: CGFloat
        /// Unclamped value following the pointer, so after hitting an end the knob waits for the
        /// pointer to come back.
        var raw: Double
    }

    private static let knobSize: CGFloat = 12
    private static let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let scale = TrackScale(range: range, width: geometry.size.width, inset: Self.knobSize / 2)
            ZStack(alignment: .leading) {
                track(scale)
                Circle()
                    .fill(Color(white: 0.94))
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .offset(x: scale.x(value) - Self.knobSize / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(scale))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                // End the drag the second click began first, so the reset is its own action.
                endDrag()
                onReset?()
            })
        }
        .frame(height: 16)
        // Faded as one layer, so the knob still covers the track instead of showing it through.
        .compositingGroup()
        .opacity(isEnabled ? 1 : 0.4)
        // A drag that ends without `onEnded`, e.g. when the inspector closes mid-drag, must still
        // end the edit, or the model would keep treating later edits as part of it.
        .onChange(of: isDragging) { _, dragging in
            if !dragging { endDrag() }
        }
        .onDisappear(perform: endDrag)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }

    private func track(_ scale: TrackScale) -> some View {
        Canvas { context, size in
            let height = Self.trackHeight
            let bar = CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
            let track = Path(roundedRect: bar, cornerRadius: height / 2)

            switch style {
            case .gradient(let colors):
                var tinted = context
                tinted.opacity = 0.75
                tinted.fill(track, with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(x: bar.minX, y: bar.midY),
                    endPoint: CGPoint(x: bar.maxX, y: bar.midY)
                ))
            case .plain, .ruler:
                context.fill(track, with: .color(.white.opacity(0.14)))
                // Values sit inset by half the knob; a fill from an end of the range starts at the
                // end of the track, so it doesn't leave that inset empty.
                let a = origin <= range.lowerBound ? bar.minX : origin >= range.upperBound ? bar.maxX : scale.x(origin)
                let b = scale.x(value)
                var filled = context
                filled.clip(to: Path(CGRect(x: min(a, b), y: bar.minY, width: abs(b - a), height: height)))
                filled.fill(track, with: .color(.white.opacity(0.62)))
            }

            if case .ruler(let tick) = style {
                var mark = (range.lowerBound / tick).rounded(.up) * tick
                while mark <= range.upperBound {
                    let x = scale.x(mark)
                    context.fill(Path(CGRect(x: x - 0.5, y: bar.maxY + 2, width: 1, height: 3)), with: .color(.white.opacity(0.3)))
                    mark += tick
                }
            }

            // Mark the origin when it isn't at an end of the track.
            if origin > range.lowerBound, origin < range.upperBound {
                let x = scale.x(origin)
                context.fill(
                    Path(roundedRect: CGRect(x: x - 0.75, y: bar.midY - 5, width: 1.5, height: 10), cornerRadius: 0.75),
                    with: .color(.white.opacity(0.4))
                )
            }
        }
    }

    private func dragGesture(_ scale: TrackScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { gesture in
                if drag == nil {
                    let start = gesture.startLocation.x
                    let onKnob = abs(start - scale.x(value)) <= Self.knobSize / 2 + 2
                    drag = Drag(lastX: start, raw: onKnob ? value : scale.value(at: start))
                    onEditingChanged(true)
                }
                guard var current = drag else { return }
                let rate = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                current.raw += Double(gesture.location.x - current.lastX) * scale.valuePerPoint * rate
                current.lastX = gesture.location.x
                drag = current
                let clamped = min(max(current.raw, range.lowerBound), range.upperBound)
                if clamped != value { value = clamped }
            }
            .onEnded { _ in endDrag() }
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        onEditingChanged(false)
    }
}

/// Maps values to horizontal positions on a track, keeping the knob inside at both ends.
private struct TrackScale {
    let range: ClosedRange<Double>
    let width: CGFloat
    let inset: CGFloat

    private var usable: CGFloat { max(width - inset * 2, 1) }
    private var span: Double { range.upperBound - range.lowerBound }
    var valuePerPoint: Double { span / Double(usable) }

    func x(_ value: Double) -> CGFloat {
        inset + CGFloat((value - range.lowerBound) / span) * usable
    }

    func value(at x: CGFloat) -> Double {
        range.lowerBound + Double((x - inset) / usable) * span
    }
}

/// A small selectable button in a row or grid of options, e.g. crop aspect ratios.
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 2)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(isSelected ? 0.2 : configuration.isPressed ? 0.12 : 0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Marks a photo whose settings differ from the defaults.
struct EditedBadge: View {
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "slider.horizontal.3")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.black.opacity(0.55), in: Circle())
            .accessibilityLabel("Edited")
    }
}

extension View {
    /// A floating label over the photo, e.g. “Original”.
    func canvasLabel() -> some View {
        font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    /// The outline of a selected thumbnail; stronger on the active photo.
    func selectionRing(_ isSelected: Bool, isActive: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.selectionRing.opacity(isActive ? 1 : 0.55), lineWidth: isActive ? 1.5 : 1)
            }
        }
    }
}

/// Formats a value with an explicit sign (“+0.30”, “−12”); zero has none.
func signedString(_ value: Double, decimals: Int) -> String {
    let magnitude = String(format: "%.\(decimals)f", abs(value))
    guard abs(value) >= 0.5 * pow(10, -Double(decimals)) else { return magnitude }
    return (value < 0 ? "\u{2212}" : "+") + magnitude
}

/// Reads what `signedString` writes, with or without a unit suffix such as “°”.
func parseSigned(_ text: String) -> Double? {
    Double(text
        .replacingOccurrences(of: "\u{2212}", with: "-")
        .replacingOccurrences(of: "°", with: "")
        .trimmingCharacters(in: .whitespaces))
}
