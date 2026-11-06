import SwiftUI
import PencilKit
import MapKit
import ELRDDomain

/// Stift für das Freihandzeichnen: Farbe, Strichstärke oder Radierer.
struct FreehandTool: Equatable {
    var color: RGBColor = MapObject.defaultColor
    var width: CGFloat = 6
    var isErasing = false

    static let widths: [(title: String, width: CGFloat)] = [("Dünn", 3), ("Mittel", 6), ("Dick", 12)]
}

/// Verbindung zur Zeichenfläche: Rückgängig, Anzahl Striche, Bild erzeugen.
@MainActor
final class FreehandController: ObservableObject {
    weak var canvas: PKCanvasView?
    @Published private(set) var strokeCount = 0

    func drawingChanged() {
        strokeCount = canvas?.drawing.strokes.count ?? 0
    }

    /// Letzten Strich entfernen (unabhängig vom Undo-Manager der Ansicht).
    func undo() {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
        var drawing = canvas.drawing
        drawing.strokes.removeLast()
        canvas.drawing = drawing
        drawingChanged()
    }

    func clear() {
        canvas?.drawing = PKDrawing()
        drawingChanged()
    }

    /// Zeichnung als transparentes PNG mit ihrem Rechteck in Ansichtskoordinaten.
    func export() -> (png: Data, rect: CGRect, pixelSize: CGSize)? {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return nil }
        let rect = canvas.drawing.bounds.insetBy(dx: -6, dy: -6).intersection(canvas.bounds)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }
        let image = canvas.drawing.image(from: rect, scale: 2)
        guard let png = image.pngData() else { return nil }
        return (png, rect, CGSize(width: rect.width * 2, height: rect.height * 2))
    }
}

/// Durchsichtige PencilKit-Fläche über der Karte. Mit Finger und Stift.
struct FreehandCanvas: UIViewRepresentable {
    let controller: FreehandController
    let tool: FreehandTool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        controller.canvas = canvas
        apply(tool, to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        apply(tool, to: canvas)
    }

    private func apply(_ tool: FreehandTool, to canvas: PKCanvasView) {
        if tool.isErasing {
            canvas.tool = PKEraserTool(.vector)
        } else {
            canvas.tool = PKInkingTool(.pen, color: UIColor(tool.color), width: tool.width)
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let controller: FreehandController

        init(controller: FreehandController) {
            self.controller = controller
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            controller.drawingChanged()
        }
    }
}

// MARK: - Darstellung auf der Karte

/// Zeichnung als Kartenfläche: das Bild über seinem geografischen Rechteck.
final class DrawingOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let image: CGImage?

    init(bounds: GeoBounds, image: CGImage?) {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east))
        boundingMapRect = MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        coordinate = bounds.center.clLocation
        self.image = image
        super.init()
    }
}

/// Zeichnet das Bild in sein Rechteck (MapKit ruft das auch abseits des Hauptthreads auf).
final class DrawingOverlayRenderer: MKOverlayRenderer {
    private let image: CGImage?
    private let imageRect: MKMapRect

    init(drawing: DrawingOverlay) {
        image = drawing.image
        imageRect = drawing.boundingMapRect
        super.init(overlay: drawing)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image else { return }
        // Das Rechteck ist die Fläche selbst; im Renderer-Raum beginnt es bei 0/0
        // (so spart man `rect(for:)`, das je nach SDK an den Hauptthread gebunden ist).
        let size = CGSize(width: imageRect.size.width, height: imageRect.size.height)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
}

/// Werkzeugleiste unten beim Freihandzeichnen: Farben, Strichstärke, Radierer,
/// Rückgängig, Abbrechen, Fertig. Große Ziele, auch mit Handschuhen.
struct FreehandToolbar: View {
    @Binding var tool: FreehandTool
    let strokeCount: Int
    let onUndo: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(MapObjectPalette.colors.indices, id: \.self) { index in
                        let entry = MapObjectPalette.colors[index]
                        Button {
                            tool.color = entry.color
                            tool.isErasing = false
                        } label: {
                            Circle()
                                .fill(Color(entry.color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if !tool.isErasing, tool.color == entry.color {
                                        Circle().strokeBorder(Color.primary, lineWidth: 3).frame(width: 46, height: 46)
                                    }
                                }
                                .frame(width: TouchTarget.minimum + 4, height: TouchTarget.minimum + 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.name)
                        .accessibilityAddTraits(!tool.isErasing && tool.color == entry.color ? .isSelected : [])
                    }
                    Divider().frame(height: 36)
                    ForEach(FreehandTool.widths.indices, id: \.self) { index in
                        let entry = FreehandTool.widths[index]
                        ChoiceChip(entry.title, isSelected: !tool.isErasing && tool.width == entry.width, minHeight: TouchTarget.minimum + 4) {
                            tool.width = entry.width
                            tool.isErasing = false
                        }
                    }
                    ChoiceChip("Radierer", isSelected: tool.isErasing, minHeight: TouchTarget.minimum + 4) {
                        tool.isErasing.toggle()
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }
            HStack(spacing: Spacing.s) {
                Button(action: onCancel) {
                    Text("Abbrechen").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: onUndo) {
                    Label("Zurück", systemImage: "arrow.uturn.backward").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(strokeCount == 0)
                Button(action: onDone) {
                    Label("Fertig", systemImage: "checkmark").font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(strokeCount == 0 ? Color.secondary : ActionFill.primary,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(strokeCount == 0)
            }
        }
        .padding(Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, 36)
        .frame(maxWidth: 680)
    }
}
