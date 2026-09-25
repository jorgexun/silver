import SwiftUI

struct InspectorView: View {
    @Environment(LibraryModel.self) private var library

    // Only the subviews read `photo.settings`, which changes on every step of a slider drag.
    var body: some View {
        if let photo = library.activePhoto {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PhotoInfoHeader(photo: photo)
                    if library.isCropping {
                        CropSection(photo: photo)
                    }
                    AdjustmentSection(title: "Light", adjustments: Adjustment.light, photo: photo)
                    AdjustmentSection(title: "Color", adjustments: Adjustment.color, photo: photo)
                    if !library.isCropping {
                        GeometrySection(photo: photo)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
        } else {
            ContentUnavailableView("No Photo Selected", systemImage: "slider.horizontal.3")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Button("Copy") { library.copyAdjustments() }
                    .help("Copy Adjustments (⇧⌘C)")
                Button("Paste") { library.pasteAdjustments(toSelected: false) }
                    .disabled(!library.canPaste)
                    .help("Paste Adjustments (⇧⌘V)")
                Spacer()
                ResetButton()
            }
            if library.selection.count > 1 {
                Button {
                    library.pasteAdjustments(toSelected: true)
                } label: {
                    Text("Paste to \(library.selection.count) Selected")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!library.canPaste)
                .help("Paste to Selected (⌥⇧⌘V)")
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
    var step: Double = 1
    var track: [Color]?

    static let light = [
        Adjustment(title: "Exposure", keyPath: \.exposure, range: -5...5, step: 0.01),
        Adjustment(title: "Contrast", keyPath: \.contrast, range: -100...100),
        Adjustment(title: "Highlights", keyPath: \.highlights, range: -100...100),
        Adjustment(title: "Shadows", keyPath: \.shadows, range: -100...100),
    ]

    static let color = [
        Adjustment(title: "Temperature", keyPath: \.temperature, range: -100...100, track: [Color(red: 0.35, green: 0.55, blue: 1), Color(red: 1, green: 0.8, blue: 0.3)]),
        Adjustment(title: "Tint", keyPath: \.tint, range: -100...100, track: [Color(red: 0.3, green: 0.8, blue: 0.35), Color(red: 0.85, green: 0.35, blue: 0.85)]),
        Adjustment(title: "Vibrance", keyPath: \.vibrance, range: -100...100),
        Adjustment(title: "Saturation", keyPath: \.saturation, range: -100...100),
    ]

    func format(_ value: Double) -> String {
        step < 1
            ? String(format: "%+.2f", value)
            : String(format: "%+.0f", value).replacingOccurrences(of: "+0", with: "0")
    }
}

private struct AdjustmentSection: View {
    let title: String
    let adjustments: [Adjustment]
    let photo: Photo

    var body: some View {
        let settings = photo.settings
        InspectorSection(title) {
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
        let keyPath = adjustment.keyPath
        let step = adjustment.step
        AdjustmentSlider(
            title: adjustment.title,
            value: Binding(
                get: { value },
                set: { newValue in
                    let rounded = (newValue / step).rounded() * step
                    library.updateActive { $0[keyPath: keyPath] = rounded }
                }
            ),
            range: adjustment.range,
            track: adjustment.track,
            format: adjustment.format,
            onEditingChanged: { editing in
                editing ? library.beginInteractiveEdit() : library.endInteractiveEdit()
            },
            onReset: {
                library.updateActive { $0[keyPath: keyPath] = 0 }
            }
        )
    }
}

private struct GeometrySection: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        InspectorSection("Crop") {
            HStack {
                Text(summary(photo.settings))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Crop & Straighten") { library.beginCrop() }
            }
        }
    }

    private func summary(_ settings: EditSettings) -> String {
        guard settings.hasGeometry else { return "Not cropped" }
        var parts: [String] = []
        if settings.crop != .full { parts.append("Cropped") }
        if settings.straighten != 0 { parts.append(String(format: "%+.1f°", settings.straighten)) }
        return parts.joined(separator: ", ")
    }
}

private struct ResetButton: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        Button("Reset") { library.resetAdjustments() }
            .disabled(library.targetPhotos.allSatisfy { !$0.isEdited })
            .help("Reset Adjustments (⌥⇧⌘R)")
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var track: [Color]?
    let format: (Double) -> String
    let onEditingChanged: (Bool) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onReset)
            .help("Double-click to reset")

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .background(alignment: .bottom) {
                    if let track {
                        LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing)
                            .frame(height: 2)
                            .clipShape(Capsule())
                            .opacity(0.8)
                            .offset(y: 4)
                    }
                }
        }
    }
}

private struct PhotoInfoHeader: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(photo.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(photo.isRaw ? "RAW" : "JPEG")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.6)))
                    .foregroundStyle(.secondary)
            }
            if let metadata = photo.metadata {
                Group {
                    if let camera = metadata.camera { Text(camera) }
                    if let lens = metadata.lens { Text(lens) }
                    if let summary = metadata.exposureSummary { Text(summary) }
                    if let date = metadata.captureDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

private struct CropSection: View {
    @Environment(LibraryModel.self) private var library
    let photo: Photo

    var body: some View {
        InspectorSection("Crop & Straighten") {
            HStack {
                Picker("Aspect", selection: Binding(
                    get: { photo.settings.aspectRatio },
                    set: { library.setAspectRatio($0) }
                )) {
                    ForEach(AspectRatio.allCases) { ratio in
                        Text(ratio.title).tag(ratio)
                    }
                }
                .labelsHidden()
                Button("Rotate Crop", systemImage: "rectangle.portrait.rotate") {
                    library.rotateCropOrientation()
                }
                .labelStyle(.iconOnly)
                .help("Switch between landscape and portrait")
            }

            AdjustmentSlider(
                title: "Straighten",
                value: Binding(get: { photo.settings.straighten }, set: { library.setStraighten($0) }),
                range: -45...45,
                format: { String(format: "%+.1f°", $0).replacingOccurrences(of: "+0.0", with: "0.0") },
                onEditingChanged: { editing in
                    editing ? library.beginStraighten() : library.endStraighten()
                },
                onReset: { library.setStraighten(0) }
            )

            HStack {
                Button("Reset") { library.resetCrop() }
                Spacer()
                Button("Cancel") { library.cancelCrop() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { library.endCrop() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
