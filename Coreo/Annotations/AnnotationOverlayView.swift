// AnnotationOverlayView.swift
// Coreo
//
// Transparent overlay that renders all currently visible annotations on top of
// the video grid. Dispatches on the selected tool to handle drawing, text
// placement, arrow creation, and erasing.

import PencilKit
import SwiftUI

/// Renders visible annotations over the video grid at the current playhead time.
/// When annotation mode is active, enables creation tools based on the selected tool.
struct AnnotationOverlayView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let containerSize: CGSize

    /// PencilKit canvas drawing state.
    @State private var currentDrawing = PKDrawing()

    /// Arrow drag tracking.
    @State private var arrowDragStart: CGPoint?
    @State private var arrowDragCurrent: CGPoint?

    /// Text placement pending input.
    @State private var pendingTextPosition: CGPoint?
    @State private var pendingTextInput: String = ""
    @State private var showTextInput: Bool = false

    var body: some View {
        ZStack {
            // Render all visible annotations (always, regardless of mode).
            ForEach(visibleAnnotations) { annotation in
                annotationView(for: annotation)
                    .opacity(annotation.opacity(at: viewModel.currentTimeSeconds))
            }

            // Tool-specific interaction layer.
            if viewModel.isAnnotationMode {
                toolLayer
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .allowsHitTesting(viewModel.isAnnotationMode)
        .alert("Add Text", isPresented: $showTextInput) {
            TextField("Annotation text", text: $pendingTextInput)
            Button("Add") { commitTextAnnotation() }
            Button("Cancel", role: .cancel) { pendingTextInput = "" }
        }
    }

    // MARK: - Tool Layer

    @ViewBuilder
    private var toolLayer: some View {
        switch viewModel.selectedAnnotationTool {
        case .pencil:
            pencilLayer
        case .text:
            textLayer
        case .arrow:
            arrowLayer
        case .eraser:
            eraserLayer
        }
    }

    // MARK: - Pencil Tool

    private var pencilLayer: some View {
        ZStack {
            PencilCanvasRepresentable(
                drawing: $currentDrawing,
                colorHex: viewModel.selectedAnnotationColorHex
            )
            .frame(width: containerSize.width, height: containerSize.height)

            // Commit button when there are strokes.
            if !currentDrawing.strokes.isEmpty {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            Haptic.light()
                            commitDrawing()
                        } label: {
                            Text("Save Drawing")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(CoreoColor.accent.opacity(0.9))
                                .cornerRadius(CornerRadius.medium)
                        }
                        .buttonStyle(.coreo)
                        .padding(Spacing.sm)
                    }
                    Spacer()
                }
            }
        }
    }

    private func commitDrawing() {
        let data = currentDrawing.dataRepresentation()
        viewModel.addDrawingAnnotation(drawingData: data)
        currentDrawing = PKDrawing()
    }

    // MARK: - Text Tool

    private var textLayer: some View {
        Color.black.opacity(0.05)
            .contentShape(Rectangle())
            .onTapGesture { location in
                Haptic.light()
                let normalized = CGPoint(
                    x: location.x / containerSize.width,
                    y: location.y / containerSize.height
                )
                pendingTextPosition = normalized
                pendingTextInput = ""
                showTextInput = true
            }
    }

    private func commitTextAnnotation() {
        guard let position = pendingTextPosition else { return }
        viewModel.addTextAnnotation(text: pendingTextInput, position: position)
        pendingTextPosition = nil
        pendingTextInput = ""
    }

    // MARK: - Arrow Tool

    private var arrowLayer: some View {
        ZStack {
            Color.black.opacity(0.05)
                .contentShape(Rectangle())
                .gesture(arrowDragGesture)

            // Live preview of arrow being drawn.
            if let start = arrowDragStart, let current = arrowDragCurrent {
                ArrowPreviewShape(start: start, end: current)
                    .stroke(
                        Color(hex: viewModel.selectedAnnotationColorHex),
                        lineWidth: 3
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var arrowDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if arrowDragStart == nil {
                    arrowDragStart = value.startLocation
                }
                arrowDragCurrent = value.location
            }
            .onEnded { value in
                guard let start = arrowDragStart else { return }
                Haptic.light()
                let normalizedStart = CGPoint(
                    x: start.x / containerSize.width,
                    y: start.y / containerSize.height
                )
                let normalizedEnd = CGPoint(
                    x: value.location.x / containerSize.width,
                    y: value.location.y / containerSize.height
                )
                viewModel.addArrowAnnotation(start: normalizedStart, end: normalizedEnd)
                arrowDragStart = nil
                arrowDragCurrent = nil
            }
    }

    // MARK: - Eraser Tool

    private var eraserLayer: some View {
        ZStack {
            Color.red.opacity(0.03)
                .contentShape(Rectangle())

            // Render visible annotations as tappable targets.
            ForEach(visibleAnnotations) { annotation in
                annotationHitArea(for: annotation)
            }

            VStack {
                Text("Tap an annotation to erase")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.top, Spacing.sm)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func annotationHitArea(for annotation: TimedAnnotation) -> some View {
        switch annotation.content {
        case .text(let text):
            let pos = CGPoint(
                x: text.position.x * containerSize.width,
                y: text.position.y * containerSize.height
            )
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 44, height: 44)
                .position(pos)
                .onTapGesture {
                    Haptic.light()
                    viewModel.deleteAnnotation(id: annotation.id)
                }
        case .arrow(let arrow):
            let mid = CGPoint(
                x: (arrow.start.x + arrow.end.x) / 2 * containerSize.width,
                y: (arrow.start.y + arrow.end.y) / 2 * containerSize.height
            )
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 44, height: 44)
                .position(mid)
                .onTapGesture {
                    Haptic.light()
                    viewModel.deleteAnnotation(id: annotation.id)
                }
        case .drawing:
            // Tap anywhere to erase a full-canvas drawing.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: containerSize.width, height: containerSize.height)
                .onTapGesture {
                    Haptic.light()
                    viewModel.deleteAnnotation(id: annotation.id)
                }
        }
    }

    // MARK: - Annotation Rendering

    private var visibleAnnotations: [TimedAnnotation] {
        viewModel.project.annotations.filter { $0.isVisible(at: viewModel.currentTimeSeconds) }
    }

    @ViewBuilder
    private func annotationView(for annotation: TimedAnnotation) -> some View {
        switch annotation.content {
        case .drawing(let drawing):
            drawingView(for: drawing)
        case .text(let text):
            TextAnnotationView(
                annotation: text,
                isSelected: viewModel.selectedAnnotationID == annotation.id,
                onTap: {
                    if viewModel.isAnnotationMode {
                        if viewModel.selectedAnnotationTool == .eraser {
                            viewModel.deleteAnnotation(id: annotation.id)
                        } else {
                            viewModel.selectedAnnotationID = annotation.id
                        }
                    }
                },
                onDrag: { newPosition in
                    viewModel.updateAnnotationPosition(id: annotation.id, position: newPosition)
                },
                containerSize: containerSize
            )
        case .arrow(let arrow):
            ArrowAnnotationView(
                annotation: arrow,
                isSelected: viewModel.selectedAnnotationID == annotation.id,
                containerSize: containerSize
            )
        }
    }

    @ViewBuilder
    private func drawingView(for drawing: DrawingAnnotation) -> some View {
        if let pkDrawing = try? PKDrawing(data: drawing.drawingData) {
            let bounds = CGRect(origin: .zero, size: containerSize)
            let image = pkDrawing.image(from: bounds, scale: 2.0)
            Image(uiImage: image)
                .resizable()
                .frame(width: containerSize.width, height: containerSize.height)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Arrow Preview Shape

/// Live preview line while dragging to create an arrow.
struct ArrowPreviewShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        // Arrowhead
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return path }
        let ux = dx / length
        let uy = dy / length
        let headLength: CGFloat = 14
        let headWidth: CGFloat = 8

        let left = CGPoint(
            x: end.x - ux * headLength + uy * headWidth / 2,
            y: end.y - uy * headLength - ux * headWidth / 2
        )
        let right = CGPoint(
            x: end.x - ux * headLength - uy * headWidth / 2,
            y: end.y - uy * headLength + ux * headWidth / 2
        )
        path.move(to: end)
        path.addLine(to: left)
        path.move(to: end)
        path.addLine(to: right)

        return path
    }
}

// MARK: - PencilKit Canvas Representable

/// UIViewRepresentable wrapping PKCanvasView for freehand annotation drawing.
struct PencilCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var colorHex: String

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(hexString: colorHex), width: 3)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
        // Update tool color if changed.
        uiView.tool = PKInkingTool(.pen, color: UIColor(hexString: colorHex), width: 3)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing

        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}

// MARK: - UIColor Hex Helper

private extension UIColor {
    convenience init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
