import SwiftUI

struct InspectorView: View {
    @Environment(LibraryModel.self) private var library

    // Only the subviews read `photo.settings`, which changes on every step of a slider drag.
    var body: some View {
        if let photo = library.activePhoto {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PhotoInfoHeader(photo: photo)
                    if library.isCropping {
                        CropSection(photo: photo)
                    }
                    // The same groups as Copy Adjustments… offers.
                    AdjustmentSection(title: "Light", groups: .light, adjustments: Adjustment.light, photo: photo)
                    AdjustmentSection(title: "White Balance", groups: .whiteBalance, adjustments: Adjustment.whiteBalance, photo: photo)
                    AdjustmentSection(title: "Color", groups: .color, adjustments: Adjustment.color, photo: photo)
                    if !library.isCropping {
                        GeometrySection(photo: photo)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InspectorFooter()
            }
        } else {
            ContentUnavailableView("No Photo Selected", systemImage: "slider.horizontal.3")
        }
    }
}

/// Copy takes the photo shown and Paste goes to every selected photo, saying how many. Reset, like
/// the section resets, is for the photo shown; resetting several is in the Photo menu.
private struct InspectorFooter: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        let count = library.targetPhotos.count
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button("Copy") { library.copyAdjustments() }
                    .help("Copy Adjustments (⇧⌘C)")
                Button(count > 1 ? "Paste to \(count)" : "Paste") { library.pasteAdjustments() }
                    .disabled(!library.canPaste)
                    .help(count > 1 ? "Paste Adjustments to \(count) Photos (⇧⌘V)" : "Paste Adjustments (⇧⌘V)")
                Spacer()
                Button("Reset") { library.resetActive(.all, actionName: "Reset Adjustments") }
                    .disabled(library.activePhoto?.isEdited != true)
                    .help("Reset This Photo's Adjustments")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(.bar)
    }
}

/// A slider bound to one value of `EditSettings`.
private struct Adjustment {
    let title: String
    let keyPath: WritableKeyPath<EditSettings, Double>
    let range: ClosedRange<Double>
    var decimals = 0
    var style: TrackStyle = .plain

    static let light = [
        Adjustment(title: "Exposure", keyPath: \.exposure, range: -5...5, decimals: 2),
        Adjustment(title: "Contrast", keyPath: \.contrast, range: -100...100),
        Adjustment(title: "Highlights", keyPath: \.highlights, range: -100...100),
        Adjustment(title: "Shadows", keyPath: \.shadows, range: -100...100),
    ]

    static let whiteBalance = [
        Adjustment(title: "Temperature", keyPath: \.temperature, range: -100...100, style: .gradient([Color(red: 0.3, green: 0.55, blue: 1), Color(red: 1, green: 0.8, blue: 0.25)])),
        Adjustment(title: "Tint", keyPath: \.tint, range: -100...100, style: .gradient([Color(red: 0.3, green: 0.8, blue: 0.35), Color(red: 0.88, green: 0.35, blue: 0.88)])),
    ]

    static let color = [
        Adjustment(title: "Vibrance", keyPath: \.vibrance, range: -100...100),
        Adjustment(title: "Saturation", keyPath: \.saturation, range: -100...100),
    ]

    var step: Double { pow(10, -Double(decimals)) }
}

private struct AdjustmentSection: View {
    @Environment(LibraryModel.self) private var library
    let title: String
    /// The settings reset by the section's reset button.
    let groups: AdjustmentGroups
    let adjustments: [Adjustment]
    let photo: Photo

    var body: some View {
        let settings = photo.settings
        let isDefault = settings.merging(groups, from: .default) == settings
        InspectorSection(title, onReset: isDefault ? nil : { library.resetActive(groups, actionName: "Reset \(title)") }) {
            ForEach(adjustments, id: \.keyPath) { adjustment in
                AdjustmentRow(adjustment: adjustment, value: settings[keyPath: adjustment.keyPath])
                    .equatable()
            }
        }
    }
}

/// Equatable on its value, so a slider drag only updates the slider being dragged.
private struct AdjustmentRow: View, Equatable {
    @Environment(LibraryModel.self) private var library
    let adjustment: Adjustment
    let value: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.adjustment.keyPath == rhs.adjustment.keyPath && lhs.value == rhs.value
    }

    var body: some View {
        let title = adjustment.title
        let keyPath = adjustment.keyPath
        let step = adjustment.step
        let decimals = adjustment.decimals
        let set = { (newValue: Double) in
            let rounded = (newValue / step).rounded() * step
            library.updateActive(actionName: title) { $0[keyPath: keyPath] = rounded }
        }
        AdjustmentSlider(
            title: title,
            value: Binding(get: { value }, set: set),
            range: adjustment.range,
            style: adjustment.style,
            format: { signedString($0, decimals: decimals) },
            onEditingChanged: { editing in
                editing ? library.beginInteractiveEdit(title) : library.endInteractiveEdit()
            },
            onReset: {
                library.updateActive(actionName: "Reset \(title)") { $0[keyPath: keyPath] = 0 }
            },
            onCommit: set
        )
    }
}

private struct GeometrySection: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        let settings = photo.settings
        InspectorSection("Crop", onReset: settings.hasGeometry ? { library.resetActive(.geometry, actionName: "Reset Crop") } : nil) {
            HStack {
                Text(summary(settings))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Crop & Straighten") { library.beginCrop() }
                    .help("Crop & Straighten (R)")
            }
        }
    }

    private func summary(_ settings: EditSettings) -> String {
        guard settings.hasGeometry else { return "Not cropped" }
        var parts: [String] = []
        if settings.crop != .full { parts.append("Cropped") }
        if settings.straighten != 0 { parts.append(signedString(settings.straighten, decimals: 1) + "°") }
        return parts.joined(separator: " · ")
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    /// Shows a reset button in the header; nil when there's nothing to reset.
    let onReset: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, onReset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Hidden rather than removed, so the header keeps its height.
                Button("Reset \(title)", systemImage: "arrow.counterclockwise") { onReset?() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Reset \(title)")
                    .opacity(onReset == nil ? 0 : 1)
                    .disabled(onReset == nil)
            }
            content
        }
    }
}

/// A named slider with its value, as in Lightroom: double-clicking the name or the slider
/// resets it, and clicking the value lets you type one.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var style: TrackStyle = .plain
    let format: (Double) -> String
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void
    /// Applies a typed value, clamped to the range.
    let onCommit: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                HStack {
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onReset)
                .help("Double-click to reset. Hold Option while dragging for finer control.")
                ValueField(text: format(value), isDefault: value == 0) { typed in
                    onCommit(min(max(typed, range.lowerBound), range.upperBound))
                }
            }
            .font(.callout)

            TrackSlider(value: $value, range: range, origin: 0, style: style, onEditingChanged: onEditingChanged, onReset: onReset)
        }
    }
}

/// A slider's value. Clicking it turns it into a field: Return or clicking another value applies
/// the typed number, Escape cancels. Single-key shortcuts are off while it's being edited.
private struct ValueField: View {
    @Environment(LibraryModel.self) private var library
    let text: String
    let isDefault: Bool
    let onCommit: (Double) -> Void

    /// The text being typed; nil when not editing.
    @State private var draft: String?
    @State private var editor = UUID()
    @FocusState private var isFocused: Bool

    var body: some View {
        if draft != nil {
            TextField("Value", text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 52)
                .padding(.horizontal, 4)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onSubmit(commit)
                .onExitCommand(perform: finish)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                // Another photo's value would take the typed number; start over instead.
                .onChange(of: library.activeID) { finish() }
                .onDisappear(perform: finish)
        } else {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(isDefault ? .secondary : .primary)
                .contentShape(Rectangle())
                .onTapGesture(perform: begin)
                .help("Click to type a value")
        }
    }

    private func begin() {
        draft = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "°", with: "")
        library.valueEditor = editor
    }

    private func commit() {
        guard let draft else { return }
        finish()
        if let value = parseSigned(draft), value.isFinite { onCommit(value) }
    }

    private func finish() {
        draft = nil
        // Another field may have started editing already.
        if library.valueEditor == editor { library.valueEditor = nil }
    }
}

private struct PhotoInfoHeader: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(photo.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(photo.isRaw ? "RAW" : "JPEG")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                if let metadata = photo.metadata {
                    Group {
                        if let camera = metadata.camera { Text(camera) }
                        if let lens = metadata.lens { Text(lens) }
                        if let date = metadata.captureDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            if let exposure = photo.metadata?.exposure, !exposure.isEmpty {
                ExposureStrip(values: exposure)
            }
        }
    }
}

/// Focal length, aperture, shutter speed and ISO side by side, like a camera's info display.
private struct ExposureStrip: View {
    let values: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1, height: 12)
                }
                Text(value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CropSection: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        let settings = photo.settings
        InspectorSection("Crop & Straighten", onReset: settings.hasGeometry ? { library.resetCrop() } : nil) {
            AspectRatioGrid(photo: photo)

            AdjustmentSlider(
                title: "Straighten",
                value: Binding(get: { settings.straighten }, set: { library.setStraighten($0) }),
                range: -45...45,
                style: .ruler(tick: 5),
                format: { signedString($0, decimals: 1) + "°" },
                onEditingChanged: { editing in
                    editing ? library.beginStraighten() : library.endStraighten()
                },
                onReset: { library.setStraighten(0) },
                onCommit: { library.setStraighten($0) }
            )

            HStack {
                Spacer()
                // Return and Escape belong to a value being typed.
                Button("Cancel") { library.cancelCrop() }
                    .keyboardShortcut(library.isEditingValue ? nil : .cancelAction)
                Button("Done") { library.endCrop() }
                    .keyboardShortcut(library.isEditingValue ? nil : .defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Aspect ratio choices, with the crop's orientation in the last cell.
private struct AspectRatioGrid: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        let selection = photo.settings.aspectRatio
        let orientation = cropOrientation
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(AspectRatio.allCases) { ratio in
                Button(ratio.title) { library.setAspectRatio(ratio) }
                    .buttonStyle(ChipButtonStyle(isSelected: ratio == selection))
            }
            HStack(spacing: 2) {
                orientationButton("Landscape", systemImage: "rectangle", isSelected: orientation == .landscape, portrait: false)
                orientationButton("Portrait", systemImage: "rectangle.portrait", isSelected: orientation == .portrait, portrait: true)
            }
            .disabled(orientation == .square)
        }
    }

    private func orientationButton(_ title: String, systemImage: String, isSelected: Bool, portrait: Bool) -> some View {
        Button(title, systemImage: systemImage) { library.setCropOrientation(portrait: portrait) }
            .labelStyle(.iconOnly)
            .buttonStyle(ChipButtonStyle(isSelected: isSelected))
            .help(title)
    }

    private var cropOrientation: CropOrientation {
        photo.geometrySize.map { CropGeometry.orientation(of: photo.settings.crop, imageSize: $0) } ?? .square
    }
}
